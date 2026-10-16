#!/bin/sh -eu

# Resolves the test framework's jars into /kotlin, each at its newest release,
# and records what was resolved in /versions.json. maven and the JDK it pulls
# in are installed by the caller and removed again afterwards.

readonly OUT=/kotlin

# Appends one test framework to the test_frameworks list the base image
# wrote in /versions.json, keeping any entry an earlier image added. Stops
# the build if the list is not found, rather than record nothing. Short grep
# flags because busybox grep has no long ones.
add_test_framework()
{
  name="${1}"
  version="${2}"
  entry="{\"name\": \"${name}\", \"version\": \"${version}\"}"
  if grep -q '"test_frameworks": \[\]' /versions.json; then
    sed -i "s|\"test_frameworks\": \[\]|\"test_frameworks\": [${entry}]|" /versions.json
  else
    sed -i "/\"test_frameworks\": \[/s|}\]|}, ${entry}]|" /versions.json
  fi
  if ! grep -q -F "${entry}" /versions.json; then
    echo "Could not add ${name} to /versions.json" >&2
    cat /versions.json >&2
    exit 1
  fi
}

# Prints the version in the one jar in /kotlin named with the given prefix,
# and stops the build if there is not exactly one.
jar_version()
{
  prefix="${1}"
  matches="$(ls "${OUT}" | grep "^${prefix}-[0-9]")"
  if [ "$(echo "${matches}" | wc -l)" != 1 ] || [ -z "${matches}" ]; then
    echo "Expected one ${prefix} jar in ${OUT}, found:" >&2
    echo "${matches}" >&2
    exit 1
  fi
  echo "${matches}" | sed "s/^${prefix}-\(.*\)\.jar$/\1/"
}

# Moves kotest and mockk to their newest releases. The versions in pom.xml
# are only a floor. Milestones (which kotest names as in 6.0.0.M1), release
# candidates, snapshots and alpha and beta builds are passed over, because a
# kata should not run on a pre-release.
mvn --batch-mode --quiet versions:update-properties \
  -DincludeProperties=kotest.version,mockk.version \
  -Dmaven.version.ignore='(?i).*[-.](alpha|beta|m[0-9]|rc|snap|pre).*' \
  -DgenerateBackupPoms=false

mvn --batch-mode --quiet dependency:copy-dependencies -DoutputDirectory="${OUT}"

# The console launcher has to be the junit-platform version kotest was built
# against, not the launcher's own newest release, which is a separate line
# that does not match it. So it is fetched at the version kotest pulled in.
readonly PLATFORM_VERSION="$(jar_version junit-platform-engine)"
mvn --batch-mode --quiet dependency:copy \
  -Dartifact="org.junit.platform:junit-platform-console-standalone:${PLATFORM_VERSION}" \
  -DoutputDirectory="${OUT}"

add_test_framework Kotest "$(jar_version kotest-runner-junit5-jvm)"
add_test_framework MockK "$(jar_version mockk-jvm)"
cat /versions.json
