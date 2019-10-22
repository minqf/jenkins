// pipeline-loader.groovy - Generic starting point for pipelines. Loads
//                          the actual pipeline code from the 'jenkins' repo
//
import groovy.transform.Field

def pipeline

if(env.RUNNING_IN_LOADER?.toBoolean()) {
    // This code runs if this file was loaded as pipeline
    return this
} else {
    // This code runs if this file was embedded directly as the script of a
    // pipeline job, it is the only part of this file that cannot be reloaded
    // dynamically
    timestamps { main() }
}

def loader_main(loader) {
    // Since this script can also be used as a pipeline, we need to define this
    // function so that the main() function runs outside of the loader node and
    // can allocate its own loader node
}

def main() {
    loader_node() {
        stage('loading code') {
            dir("exported-artifacts") { deleteDir() }
            def checkoutData = checkout_jenkins_repo()
            if(checkoutData.CODE_FROM_EVENT) {
                echo "Code loaded from STDCI repo event"
            }
            if (!env?.NODE_IS_EPHEMERAL?.toBoolean()) {
                run_jjb_script('cleanup_slave.sh')
                run_jjb_script('global_setup.sh')
            }
            dir('jenkins') {
                def pipeline_file
                if(
                    checkoutData.CODE_FROM_EVENT
                    && !(env.RUNNING_IN_LOADER?.toBoolean())
                    && loader_was_modified()
                ) {
                    echo "Going to reload the pipeline loader"
                    pipeline_file = 'pipeline-loader.groovy'
                } else {
                    pipeline_file = get_pipeline_for_job(env.JOB_NAME)
                }
                if(pipeline_file == null) {
                    error "Could not find a matching pipeline for this job"
                }
                echo "Loading pipeline script: '${pipeline_file}'"
                dir('pipelines') {
                    withEnv(['RUNNING_IN_LOADER=true']) {
                        pipeline = load_code(pipeline_file)
                    }
                }
            }
        }
        echo "Launching pipeline script"
        if(pipeline.metaClass.respondsTo(pipeline, 'loader_main')) {
            withEnv(['RUNNING_IN_LOADER=true']) {
                pipeline.loader_main(this)
            }
        } else {
            withEnv(['RUNNING_IN_LOADER=true']) {
                pipeline.main()
            }
        }
        if (!env?.NODE_IS_EPHEMERAL?.toBoolean()) {
            run_jjb_script('global_setup_apply.sh')
        }
    }
    if(
        pipeline.metaClass.respondsTo(pipeline, 'loader_main') &&
        pipeline.metaClass.respondsTo(pipeline, 'main')
    ) {
        withEnv(['RUNNING_IN_LOADER=true']) {
            pipeline.main()
        }
    }
}

def loader_node(Closure code) {
    if(env.LOADER_NODE_LABEL?.endsWith('-container')) {
        // If the requested node label is for a container we're going to mostly
        // ignore it and just allocate a container in K8s

        // Default image value is based on what is in use as the code is being
        // written, to maintain compatibility, over time we should migrate to a
        // default value that is defined in JJB.
        def default_image = \
            "docker.io/ovirtinfra/el7-loader-node:e786721a956a3e261142d6ff7614117e3f6f302b"
        def image = env.LOADER_IMAGE ?: default_image
        def pod_label = env.BUILD_TAG
        if(pod_label.length() > 63) {
            // Limit label length by shortening `poll-upstream-sources` to `poll`
            pod_label = pod_label.replace('poll-upstream-sources', 'poll')
        }
        if(pod_label.length() > 63) {
            // If label is still too long, just take the last 63 characters
            pod_label = pod_label[-63..-1]
            // Make sure the first character is an alpha numeric character'
            pod_label = pod_label.replaceFirst('^[^a-zA-Z0-9]*', '')
        }
        podTemplate(
            // Default to the cloud defined by the OpenShift Jenkins image
            cloud: env.CONTAINER_CLOUD ?: 'openshift',
            // Specify POD label manually to support older K8s plugin versions
            label: pod_label,
            yaml: """\
                apiVersion: v1
                kind: Pod
                metadata:
                  namespace: "${env.OPENSHIFT_PROJECT}"
                  labels:
                    podType: "loader-node"
                spec:
                  containers:
                    - name: jnlp
                      image: "${image}"
                      imagePullPolicy: "IfNotPresent"
                      tty: true
                      resources:
                        limits:
                          memory: 500Mi
                        requests:
                          memory: 500Mi
                  nodeSelector:
                    type: vm
                    zone: ci
                  serviceAccount: jenkins-loader-node
            """.stripIndent()
        ) {
            node(pod_label) {
                withEnv(["NODE_IS_EPHEMERAL=true"]) {
                    code()
                }
            }
        }
    } else {
        // We preserve older functionality for un-containerized loaders
        node(env.LOADER_NODE_LABEL) {
            withEnv(["NODE_IS_EPHEMERAL=false"]) {
                code()
            }
        }
    }
}

@Field def loaded_code = [:]

def load_code(String code_file) {
    if(!(code_file in loaded_code)) {
        def code = load(code_file)
        if(code.metaClass.respondsTo(code, 'on_load')) {
            code.on_load(this)
        }
        loaded_code[code_file] = code
    }
    return loaded_code[code_file]
}

// We're going to save the jenkins repo checkout SHA because we may need this
// information later if we're also running a job for the jenkins repo itself
@Field String jenkins_checkout_sha

def checkout_jenkins_repo() {
    String url_prefix = env.DEFAULT_SCM_URL_PREFIX ?: 'https://gerrit.ovirt.org'
    String configured_url = env.STDCI_SCM_URL ?: "${url_prefix}/jenkins"
    def jenkins_urls = \
        ([configured_url] as Set) \
        + ((env.STDCI_SCM_URL_ALIASES?.split() ?: []) as Set)
    String event_url = \
        env.STD_CI_CLONE_URL ?: "https://${env.GERRIT_NAME}/${env.GERRIT_PROJECT}"
    String refspec = env.STDCI_SCM_REFSPEC ?: 'refs/heads/master'
    String url = configured_url
    def code_from_event = false
    List extra_remotes = []
    if(event_url in jenkins_urls) {
        // Use extra_remotes to also fetch the unchanged code so we can
        // calculate diff
        extra_remotes = mk_git_remotes(refspec, url, 'older_head')
        refspec = env.STD_CI_REFSPEC ?: env.GERRIT_REFSPEC
        url = event_url
        code_from_event = true
    }
    def checkoutData = checkout_repo(
        repo_name: 'jenkins',
        refspec: refspec,
        url: url,
        extra_remotes: extra_remotes,
    )
    if ('GIT_COMMIT' in checkoutData) {
        jenkins_checkout_sha = checkoutData.GIT_COMMIT
    }
    checkoutData.CODE_FROM_EVENT = code_from_event
    return checkoutData
}

def checkout_repo(
    String repo_name,
    String refspec='refs/heads/master',
    String url=null,
    String head=null,
    String clone_dir_name=null,
    List extra_remotes=null
) {
    def checkoutData
    if(url == null) {
        url_prefix = env.DEFAULT_SCM_URL_PREFIX ?: 'https://gerrit.ovirt.org'
        url = "${url_prefix}/${repo_name}"
    }
    if(head == null) {
        head = 'myhead'
    }
    if(clone_dir_name == null) {
        clone_dir_name = repo_name
    }
    def remotes = mk_git_remotes(refspec, url, 'myhead') + (extra_remotes ?: [])
    dir(clone_dir_name) {
        checkoutData = checkout(
            changelog: false, poll: false, scm: [
                $class: 'GitSCM',
                branches: [[name: head]],
                userRemoteConfigs: remotes,
                extensions: [
                    [$class: 'CleanBeforeCheckout'],
                    [$class: 'PerBuildTag'],
                    [$class: 'CloneOption', timeout: 20, honorRefspec: true],
                    [$class: 'UserIdentity',
                        email: env.GIT_AUTHOR_NAME,
                        name: env.GIT_AUTHOR_EMAIL
                    ],
                ],
            ]
        )
        sshagent(['std-ci-git-push-credentials']) {
            sh """
                WORKSPACE="\${WORKSPACE:-\$(dirname \$PWD)}"

                usrc="\$WORKSPACE/jenkins/scripts/usrc.py"
                [[ -x "\$usrc" ]] || usrc="\$WORKSPACE/jenkins/scripts/usrc_local.py"

                "\$usrc" --log -d get
            """
        }
    }
    if(!('GIT_COMMIT' in checkoutData) && jenkins_checkout_sha != null) {
        // We found out there are some cases when running jobs for the jenkins
        // repo itself where the checkout data does not include the GIT_COMMIT
        // when checking it out a 2nd time. So we fill-in the data from the
        // first time we checked it out.
        checkoutData.GIT_COMMIT = jenkins_checkout_sha
    }
    return checkoutData
}

def mk_git_remotes(String refspec, String url, String head_name=null) {
    def extra_remotes = []
    if(refspec.matches('^[A-Fa-f0-9]+$')) {
        // If we were given a Git SHA as a refspec, we need to ensure the
        // remote branches are fetched, because fetch with a Git SHA only works
        // if that commit was already fetched via fetching one of the branches
        extra_remotes += [
            [refspec: "+refs/heads/*:refs/remotes/origin/*", url: url]
        ]
    }
    if(head_name == null) {
        head_name = refspec
    }
    return extra_remotes + [[refspec: "+${refspec}:$head_name", url: url]]
}

def checkout_repo(Map named_args) {
    if('refspec' in named_args) {
        return checkout_repo(
            named_args.repo_name, named_args.refspec, named_args.url,
            named_args.head, named_args.clone_dir_name,
            named_args.extra_remotes,
        )
    } else {
        return checkout_repo(named_args.repo_name)
    }
}

def loader_was_modified() {
    def result = sh(
        label: 'pipeline-loader diff check',
        returnStatus: true,
        script: """\
            usrc="\$WORKSPACE/jenkins/scripts/usrc.py"
            [[ -x "\$usrc" ]] || usrc="\$WORKSPACE/jenkins/scripts/usrc_local.py"

            "\$usrc" --log -d changed-files HEAD older_head |\
                grep 'pipeline-loader.groovy\$'
        """
    )
    return (result == 0)
}

def run_jjb_script(script_name) {
    def script_path = "jenkins/jobs/confs/shell-scripts/$script_name"
    echo "Running JJB script: ${script_path}"
    def script = readFile(script_path)
    withEnv(["WORKSPACE=${pwd()}"]) {
        sh script
    }
}

@NonCPS
def get_pipeline_for_job(name) {
    print("Searching pipeline script for '${name}'")
    def job_to_pipelines = [
        /^standard-enqueue$/: '$0.groovy',
        /^standard-manual-runner$/: 'standard-stage.groovy',
        /^(.*)_standard-(.*)$/: 'standard-stage.groovy',
        /^(.*)_change-queue(-tester)?$/: 'change-queue$2.groovy',
        /^deploy-to-.*$/: 'deployer.groovy',
        /^(.*)_gate$/: 'gate.groovy'
    ]
    return job_to_pipelines.findResult { key, value ->
        def match = (name =~ key)
        if(match.asBoolean()) {
            return match.replaceAll(value)
        }
    }
}
