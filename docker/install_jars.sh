#!/bin/sh -eu

# Resolves ScalaTest's jars into /scalatest at its newest release, and records
# what was resolved in /versions.json. maven and the JDK it pulls in are
# installed by the caller and removed again afterwards.

readonly OUT=/scalatest

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

# Moves ScalaTest to its newest release. The version in pom.xml is only a
# floor. Milestones, release candidates, snapshots (which ScalaTest publishes
# as SNAP1, SNAP2 and so on) and alpha and beta builds are passed over,
# because a kata should not run on a pre-release.
mvn --batch-mode --quiet versions:update-properties \
  -DincludeProperties=scalatest.version \
  -Dmaven.version.ignore='(?i).*[-.](alpha|beta|m[0-9]|rc|snap|pre).*' \
  -DgenerateBackupPoms=false

mvn --batch-mode --quiet dependency:copy-dependencies -DoutputDirectory="${OUT}"

# ScalaTest is published against an older Scala 3 than this image compiles
# with, so resolving it also drags in that older standard library. Two standard
# libraries on one classpath is a coin toss over which one a run gets, so the
# resolved copies go and the compiler's own, in /scala, are the only ones left.
rm -f "${OUT}"/scala-library-*.jar "${OUT}"/scala3-library_3-*.jar

readonly JARS="$(ls "${OUT}" | grep '^scalatest_3-[0-9]')"
if [ "$(echo "${JARS}" | wc -l)" != 1 ] || [ -z "${JARS}" ]; then
  echo "Expected one scalatest_3 jar in ${OUT}, found:" >&2
  echo "${JARS}" >&2
  exit 1
fi
add_test_framework ScalaTest "$(echo "${JARS}" | sed 's/^scalatest_3-\(.*\)\.jar$/\1/')"
cat /versions.json
