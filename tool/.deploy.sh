#!/bin/bash

# This script is used by .deploy.yaml

# Always exit on error
set -e
# Print an error message, if exiting non-zero
trap 'if [ $? -ne 0 ]; then echo "Deployment failed!"; fi' EXIT

# This only works with PROJECT_ID defined
if [ -z "$PROJECT_ID" ]; then
  echo 'PROJECT_ID must be specified';
  exit 1;
fi

if [ "$PROJECT_ID" = 'dartlang-pub' ]; then
  # Use TAG_NAME as appengine version
  if [ -z "$TAG_NAME" ]; then
    echo 'TAG_NAME must be specified';
    exit 1;
  fi

  if [[ "$TAG_NAME" != *-all ]]; then
    echo 'This script is only intended for use on staging-<name> branches'
    exit 1;
  fi

  # Remove the -all suffix to create a version name.
  APP_VERSION="${TAG_NAME%-all}"
else
  # Use BRANCH_NAME as appengine version
  if [ -z "$BRANCH_NAME" ]; then
    echo 'BRANCH_NAME must be specified';
    exit 1;
  fi

  if [[ "$BRANCH_NAME" != staging-* ]]; then 
    echo 'This script is only intended for use on staging-<name> branches'
    exit 1;
  fi

  # Remove the staging- prefix to create a version name.
  APP_VERSION="${BRANCH_NAME#staging-}"

  # Setup number of instances to one
  # NOTICE: this modifies the current folder, which is a bit of a hack
  sed -i 's/_num_instances:[^\n]*/_num_instances: 1/' app.yaml search.yaml dartdoc.yaml analyzer.yaml
fi

# Disable interactive gcloud prompts
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

echo "### Deploying index.yaml"
time -p gcloud --project "$PROJECT_ID" app deploy index.yaml

# This script will build image:
IMAGE="gcr.io/$PROJECT_ID/pub-dev-$APP_VERSION-image"

echo "### Building docker image: $IMAGE"
time -p gcloud --project "$PROJECT_ID" builds submit --timeout=1500 -t "$IMAGE"

echo "### Start deploying search.yaml (version: $APP_VERSION)"
time -p gcloud --project "$PROJECT_ID" app deploy --no-promote -v "$APP_VERSION" --image-url "$IMAGE" 'search.yaml' &
SEARCH_PID=$!

echo "### Start deploying dartdoc.yaml (version: $APP_VERSION)"
time -p gcloud --project "$PROJECT_ID" app deploy --no-promote -v "$APP_VERSION" --image-url "$IMAGE" 'dartdoc.yaml' &
DARTDOC_PID=$!

echo "### Start deploying analyzer.yaml (version: $APP_VERSION)"
time -p gcloud --project "$PROJECT_ID" app deploy --no-promote -v "$APP_VERSION" --image-url "$IMAGE" 'analyzer.yaml' &
ANALYZER_PID=$!

echo "### Start deploying app.yaml (version: $APP_VERSION)"
time -p gcloud --project "$PROJECT_ID" app deploy --no-promote -v "$APP_VERSION" --image-url "$IMAGE" 'app.yaml'
echo "### app.yaml deployed"

wait $SEARCH_PID
echo "### search.yaml deployed"
wait $DARTDOC_PID
echo "### dartdoc.yaml deployed"
wait $ANALYZER_PID
echo "### analyzer.yaml deployed"

echo ''
echo '### Site updated, see:'
echo "https://$APP_VERSION-dot-$PROJECT_ID.appspot.com/"
echo ''
echo 'Traffic must be migrated manually.'
