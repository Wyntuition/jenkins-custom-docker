#!/usr/bin/env bash
# See https://github.com/kabisaict/jenkins-docker for more information.
#
# Usage:
# run-containerized [CI command]
#
# Examples:
# run-containerized 'bin/ci'
# run-containerized 'mvn clean install'
set -o pipefail
trap cleanupContainer EXIT

function cleanupContainer() {
  if [ -n "$CID" ]; then
    CONTAINER_RUNNING=$(docker inspect --format='{{.State.Running}}' $CID)
    if [ $CONTAINER_RUNNING = "true" ]; then
      echo "Cleaning up docker container"

      # In regular workflows this is done automatically, but when the job is aborted
      # and the container is killed this cleanup won't happen, so do it here.
      docker exec $CID chown -R $(id -u `whoami`) /workspace
      docker kill $CID > /dev/null
    fi
  fi
}

function abort() {
  echo "$(tput setaf 1)$1$(tput sgr 0)"
  exit 1
}

if [ $# -ne 1 ]; then
  abort "$0 requires exactly one argument (of bash script)."
fi

# DOCKER_OPTS is now deprecated in favor of DOCKER_RUN_OPTS.
# If it is set assign it to DOCKER_RUN_OPTS and print a warning.
if [ -n "$DOCKER_OPTS" ]; then
  >&2 echo '$DOCKER_OPTS is deprecated, please use $DOCKER_RUN_OPTS'
  DOCKER_RUN_OPTS=$DOCKER_OPTS
fi

# Forward the SSH agent to the Docker container, useful in combination with
# https://wiki.jenkins-ci.org/display/JENKINS/SSH+Agent+Plugin
if [[ -n $SSH_AUTH_SOCK ]]; then
  DOCKER_RUN_OPTS="$DOCKER_RUN_OPTS -v $SSH_AUTH_SOCK:/tmp/auth.sock -e SSH_AUTH_SOCK=/tmp/auth.sock"
fi

# Where to store cachable artifacts. Docker containers ran by this script get
# a /cache directory that's unique to the job and can be used to store any build
# artifacts that should persist across builds. Think about Ruby gems, the local
# Java Maven repository etc.
CACHE_DIR=${CACHE_DIR:-/ci/cache}
BUILD_CACHE_DIR="$CACHE_DIR/$JOB_NAME"

# Projects that want to use this setup should maintain a Dockerfile in dockerfiles/ci
# that describes the required build environment.
DOCKER_CONTEXT_DIR=${DOCKER_CONTEXT_DIR:-$WORKSPACE/dockerfiles/ci}

if [ ! -d "$DOCKER_CONTEXT_DIR" ]; then
  abort "No Dockerfile found at $DOCKER_CONTEXT_DIR"
fi

cd "$DOCKER_CONTEXT_DIR"

# Deduce a tag name for the container we're going to build based on the Jenkins job name
DOCKER_TAG_NAME=$(echo $JOB_NAME | tr '[:upper:]' '[:lower:]' | sed 's/[^-a-z0-9_.]//g')

# copy stdout to a new fd so we can display and capture it
exec 5>&1

echo "Building $DOCKER_TAG_NAME Docker image, this can take some..."
BUILD=$(docker build $DOCKER_BUILD_OPTS -t $DOCKER_TAG_NAME . | tee >(cat - >&5))
[ $? -eq 0 ] || abort "Docker image failed to build, check your Dockerfile."

# Determine the image ID we've just built
DOCKER_IMG=$(echo "$BUILD" | tail -n 1 | rev | cut -d ' ' -f1 | rev)

# Now actually run the Docker container.
# We mount the jobs workspace under /workspace and a directory to store build
# caches/artifacts under /cache.
#
# Additional Docker run CLI options can be passed in by setting a DOCKER_RUN_OPTS environment
# variable.
#
# If the container contains a /usr/local/bin/init-container script we execute this first,
# before executing the actual CI command. Use this to start services like Postgres, Redis etc,
# or to run other dynamic configuration of the build environment.
#
# After the CI build has finished we chown the workspace to user executing this script.
# In practise this means the workspace is properly owned by the user running Jenkins.
#
# Note that containers are run detached because due to how the Docker CLI works it's
# not trivial to cleanup the Docker container when the Jenkins job get's aborted if
# containers are run in the foreground.
set -x
CID=$(docker run -it -d -v "$WORKSPACE:/workspace" \
                        -v "$BUILD_CACHE_DIR:/cache" \
                        -w /workspace \
                        -e 'CI=true' \
                        -e 'DISPLAY=:0' \
                        $DOCKER_RUN_OPTS $DOCKER_IMG \
                        bash -c "INIT=/usr/local/bin/init-container ;\
                        [ -e \$INIT ] && \$INIT ;\
                        $* ;\
                        JOB_RESULT=\$? ; chown -R $(id -u `whoami`) /workspace ;\
                        (exit \$JOB_RESULT)")
set +x

# This is used for debugging. If you run this script locally while setting up or
# debugging your CI build environment you could pass 'bash' as CI command and get
# an interactive environment.
[[ "$@" = "bash" ]] && docker attach $CID

# Tail the logs of the container so we can see the build output
docker logs -f $CID &

# Wait for the container to exit when the CI command is done.
exit $(docker wait $CID)