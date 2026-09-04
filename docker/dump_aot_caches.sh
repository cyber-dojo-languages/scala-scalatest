#!/bin/bash -Eeu

# Dumps an ahead-of-time cache for the compiler and one for the test runner.
#
# A kata is compiled and run in a container that is thrown away afterwards, so
# both JVMs load every class they need from the jars each time. An AOT cache
# holds those classes in the form the JVM wants them, and reading one back
# costs a fraction of parsing the jars again. Together the two roughly halve a
# run: about 1.1 seconds of compiling and running becomes about 0.6.
#
# There is one cache per JVM because a cache is validated against the classpath
# of the JVM reading it, and these two have nothing in common. Neither
# classpath mentions the kata: the compiler's JVM classpath is the compiler's
# own jar, with the kata's classpath passed to the compiler rather than to its
# JVM, and the runner reaches the kata's classes through ScalaTest's -R runpath
# instead of through the JVM's classpath. That is what keeps both caches valid
# whatever the learner writes.
#
# The classes recorded are the ones a run actually loads, so the throwaway kata
# below is shaped like a real one: a source file, and a suite asserting against
# it. Caches dumped from this kata speed up any other, the classes being the
# compiler's and ScalaTest's rather than the kata's.

# The same classpath cyber-dojo.sh builds. It has to be the same: a cache
# recorded against one classpath is refused by a JVM started with another, and
# a refused cache costs a run everything this script saves it.
readonly CLASSPATH_JARS="$(ls /scala/*.jar /scalatest/*.jar | tr '\n' ':')"
readonly CP="${CLASSPATH_JARS%:}"

readonly WARMUP_DIR=/tmp/dump_aot_caches
mkdir -p /aot "${WARMUP_DIR}/classes"
cd "${WARMUP_DIR}"

cat > Answer.scala <<'SCALA'
object Answer {

  def answer(): Int = 6 * 7
}
SCALA

cat > AnswerTest.scala <<'SCALA'
import org.scalatest.funsuite.AnyFunSuite

class AnswerTest extends AnyFunSuite {

  test("the caches are dumped from a passing test") {
    assert(Answer.answer() == 42)
  }
}
SCALA

# The flags each JVM is given when a kata runs, minus the flag naming the cache
# itself. A cache is keyed on these too, so a run started with different ones
# would be handed a cache it has to refuse.
readonly COMPILER_OPTS='-Xmx768m -Xms768m -XX:+UseSerialGC --sun-misc-unsafe-memory-access=allow'
readonly RUNNER_OPTS='-Xmx768m -Xms768m -XX:+UseSerialGC --sun-misc-unsafe-memory-access=allow'

# -XX:TieredStopAtLevel=1 is deliberately absent from both. It belongs to a
# run, which lasts a fraction of a second and never reaches the later tiers,
# but a dump wants the JVM to behave as it normally would while it records.
# It is not part of what a cache is keyed on, so leaving it out here does not
# stop the cache being used by a run that sets it.

JAVA_OPTS="${COMPILER_OPTS} -XX:AOTCacheOutput=/aot/scalac.aot" \
  scalac -classpath "${CP}" -d "${WARMUP_DIR}/classes" Answer.scala AnswerTest.scala

java ${RUNNER_OPTS} -XX:AOTCacheOutput=/aot/scalatest.aot \
  -classpath "${CP}" \
  org.scalatest.tools.Runner -R "${WARMUP_DIR}/classes" -oW

# Written here by root and read by the sandbox user a kata runs as, who owns
# nothing in this image. Without this the JVM says only that it could not use
# the cache, and every run pays the cost this script exists to remove.
chmod 0644 /aot/scalac.aot /aot/scalatest.aot

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# A cache the JVM refuses looks exactly like a cache that was never worth
# having: the run is merely as slow as it was before, and nothing says so
# unless cds logging is on, which it is not when a kata runs. So each cache is
# measured here, against the same command run without it, while there is still
# someone to read the answer.
#
# The comparison is a ratio rather than a number of seconds because this script
# also runs under emulation, when the arm64 half of the image is built on an
# amd64 machine. Emulated, every run is several times slower, and any threshold
# in seconds that fits one host fails the other. A ratio holds either way.
readonly RUNS=3

# Echoes the seconds taken to run its arguments RUNS times. Each run's output
# is discarded but its exit status is not: a command that failed would return
# almost immediately and be read as a fast one.
seconds_for()
{
  local _
  local -r start="$(date +%s.%N)"
  for _ in $(seq "${RUNS}"); do
    "$@" > /dev/null 2>&1 || { >&2 echo "FAILED: $*"; exit 42; }
  done
  local -r finish="$(date +%s.%N)"
  awk "BEGIN { printf \"%.3f\", ${finish} - ${start} }"
}

# Insists the cached form of a command is meaningfully quicker than the
# uncached one. A cache being refused shows up here as a ratio near 1.
assert_cache_pays()
{
  local -r name="${1}"
  local -r cold="${2}"
  local -r warm="${3}"
  echo "[${name}] ${RUNS} runs: cold ${cold}s, warm ${warm}s"
  if [ "$(awk "BEGIN { print (${cold} > ${warm} * 1.25) }")" != '1' ]; then
    >&2 echo "Expected replaying ${name}'s AOT cache to be clearly quicker than not."
    >&2 echo "The cache is being refused, so every kata pays to load these classes."
    exit 42
  fi
}

compile()
{
  JAVA_OPTS="${COMPILER_OPTS} ${1}" \
    scalac -classpath "${CP}" -d "${WARMUP_DIR}/classes" Answer.scala AnswerTest.scala
}

run_tests()
{
  java ${RUNNER_OPTS} ${1} \
    -classpath "${CP}" \
    org.scalatest.tools.Runner -R "${WARMUP_DIR}/classes" -oW
}

assert_cache_pays scalac \
  "$(seconds_for compile '')" \
  "$(seconds_for compile '-XX:AOTCache=/aot/scalac.aot')"

assert_cache_pays scalatest \
  "$(seconds_for run_tests '')" \
  "$(seconds_for run_tests '-XX:AOTCache=/aot/scalatest.aot')"

cd /
rm -rf "${WARMUP_DIR}"

ls -l /aot
