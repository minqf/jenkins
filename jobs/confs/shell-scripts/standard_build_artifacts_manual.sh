#!/bin/bash -e
echo "shell-scripts/standard_build_artifacts_manual.sh"
# PARAMETERS
#
# project
#     Name of the project it runs on, specifically the dir where the code
#     has been cloned
#
# distro
#     Distribution it should create the rpms for
#     (usually el<version>, fc<version>)
#
# arch
#     Architecture to build the packages for

distro="{distro}"
arch="{arch}"
project="{project}"
WORKSPACE="$PWD"

# remove any previous tarball from project directory
rm -f "${{WORKSPACE}}/${{project}}"/*tar.gz

# move the tarball to the project directory
mv TARBALL_FILE "${{WORKSPACE}}/${{project}}/${{TARBALL_FILE}}"


cd "./$project"
"$WORKSPACE"/jenkins/mock_configs/mock_runner.sh \
    --execute-script automation/build-artifacts-manual.sh \
    --mock-confs-dir "$WORKSPACE"/jenkins/mock_configs \
    --try-proxy \
    "$distro.*$arch"

# move the exported artifacts to jenkins workspace, as they are created in the
# project root
mkdir -p "$WORKSPACE"/exported-artifacts
sudo chown -R "$USER:$USER" "$WORKSPACE/exported-artifacts"
if ls "$WORKSPACE/$project/exported-artifacts/"* &>/dev/null; then
    sudo mv "$WORKSPACE/$project/exported-artifacts/"* \
            "$WORKSPACE/exported-artifacts/"
    sudo rmdir "$WORKSPACE/$project/exported-artifacts/"
fi
exit 0