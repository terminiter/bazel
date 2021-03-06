#!/bin/bash
#
# Copyright 2016 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# An end-to-end test that Bazel's experimental UI produces reasonable output.

# Load the test setup defined in the parent directory
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CURRENT_DIR}/../integration_test_setup.sh" \
  || { echo "integration_test_setup.sh not found!" >&2; exit 1; }

#### SETUP #############################################################

set -e

function set_up() {
  mkdir -p pkg
  cat > pkg/true.sh <<EOF
#!/bin/sh
exit 0
EOF
  chmod 755 pkg/true.sh
  cat > pkg/false.sh <<EOF
#!/bin/sh
exit 1
EOF
  chmod 755 pkg/false.sh
  cat > pkg/slowtest.sh <<EOF
#!/bin/sh
sleep 1
exit 0
EOF
  chmod 755 pkg/slowtest.sh
  cat > pkg/BUILD <<EOF
sh_test(
  name = "true",
  srcs = ["true.sh"],
)
sh_test(
  name = "slow",
  srcs = ["slowtest.sh"],
)
test_suite(
  name = "suite",
  tests = ["true"],
)
sh_test(
  name = "flaky",
  srcs = ["false.sh"],
  flaky = True,
)
genrule(
  name = "fails_to_build",
  outs = ["fails_to_build.txt"],
  cmd = "false",
)
genrule(
  name = "output_files_and_tags",
  outs = ["out1.txt"],
  cmd = "echo foo > \\"\$@\\"",
  tags = ["tag1", "tag2"]
)
EOF
}

#### TESTS #############################################################

function test_basic() {
  # Basic properties of the event stream
  # - a completed target explicity requested should be reported
  # - after success the stream should close naturally, without any
  #   reports about aborted events.
  bazel test --experimental_build_event_text_file=$TEST_log pkg:true \
    || fail "bazel test failed"
  expect_log 'pkg:true'
  # Build Finished
  expect_log 'build_finished'
  expect_log 'overall_success: true'
  expect_log 'finish_time'
  expect_not_log 'aborted'
}

function test_suite() {
  # ...same true when running a test suite containing that test
  bazel test --experimental_build_event_text_file=$TEST_log pkg:suite \
    || fail "bazel test failed"
  expect_log 'pkg:true'
  expect_not_log 'aborted'
}

function test_test_summary() {
  # Requesting a test, we expect
  # - precisely one test summary (for the single test we run)
  # - that is properly chained (no additional progress events)
  # - the correct overall status being reported
  bazel test --experimental_build_event_text_file=$TEST_log pkg:true \
    || fail "bazel test failed"
  expect_log_once '^test_summary '
  expect_log_once '^progress '
  expect_not_log 'aborted'
  expect_log_once 'status.*PASSED'
  expect_not_log 'status.*FAILED'
  expect_not_log 'status.*FLAKY'
}

function test_test_inidivual_results() {
  # Requesting a test, we expect
  # - precisely one test summary (for the single test we run)
  # - that is properly chained (no additional progress events)
  bazel test --experimental_build_event_text_file=$TEST_log \
    --runs_per_test=2 pkg:true \
    || fail "bazel test failed"
  expect_log '^test_result'
  expect_log 'run.*1'
  expect_log 'success.*true'
  expect_log_once '^test_summary '
  expect_log_once '^progress '
  expect_not_log 'aborted'
}

function test_test_attempts() {
  # Run a failing test declared as flaky.
  # We expect to see 3 attempts to happen, and also find the 3 xml files
  # mentioned in the stream.
  # Moreover, as the test consistently fails, we expect the overall status
  # to be reported as failure.
  ( bazel test --experimental_build_event_text_file=$TEST_log pkg:flaky \
    && fail "test failure expected" ) || true
  expect_log 'attempt.*1$'
  expect_log 'attempt.*2$'
  expect_log 'attempt.*3$'
  expect_log_once '^test_summary '
  expect_log_once 'status.*FAILED'
  expect_not_log 'status.*PASSED'
  expect_not_log 'status.*FLAKY'
  expect_log_once '^progress '
  expect_not_log 'aborted'
  expect_log '^test_result'
  expect_log 'test_action_output'
  expect_log 'flaky/.*attempt_1.xml'
  expect_log 'flaky/.*attempt_2.xml'
  expect_log 'flaky/.*test.xml'
  expect_log 'name:.*test.log'
  expect_log 'name:.*test.xml'
}

function test_test_runtime() {
  bazel test --experimental_build_event_text_file=$TEST_log pkg:slow \
    || fail "bazel test failed"
  expect_log 'pkg:slow'
  expect_log '^test_result'
  expect_log 'test_attempt_duration_millis.*[1-9]'
  expect_log 'build_finished'
  expect_log 'overall_success: true'
  expect_log 'finish_time'
  expect_not_log 'aborted'
}

function test_test_attempts_multi_runs() {
  # Sanity check on individual test attempts. Even in more complicated
  # situations, with some test rerun and some not, all events are properly
  # announced by the test actions (and not chained into the progress events).
  ( bazel test --experimental_build_event_text_file=$TEST_log \
    --runs_per_test=2 pkg:true pkg:flaky \
    && fail "test failure expected" ) || true
  expect_log 'run.*1'
  expect_log 'attempt.*2'
  expect_log_once '^progress '
  expect_not_log 'aborted'
}

function test_test_attempts_multi_runs_flake_detection() {
  # Sanity check on individual test attempts. Even in more complicated
  # situations, with some test rerun and some not, all events are properly
  # announced by the test actions (and not chained into the progress events).
  ( bazel test --experimental_build_event_text_file=$TEST_log \
    --runs_per_test=2 --runs_per_test_detects_flakes pkg:true pkg:flaky \
    && fail "test failure expected" ) || true
  expect_log 'run.*1'
  expect_log 'attempt.*2'
  expect_log_once '^progress '
  expect_not_log 'aborted'
}

function test_cached_test_results() {
  # Verify that both, clean and cached test results are reported correctly,
  # including the appropriate reference to log files.
  bazel clean --expunge
  bazel test --experimental_build_event_text_file=$TEST_log pkg:true \
    || fail "Clean testing pkg:true failed"
  expect_log '^test_result'
  expect_log 'name:.*test.log'
  expect_log 'name:.*test.xml'
  expect_log_once '^progress '
  expect_not_log 'aborted'
  bazel test --experimental_build_event_text_file=$TEST_log pkg:true \
    || fail "Second testing of pkg:true failed"
  expect_log '^test_result'
  expect_log 'name:.*test.log'
  expect_log 'name:.*test.xml'
  expect_log_once '^progress '
  expect_not_log 'aborted'
}

function test_target_complete() {
  bazel build --verbose_failures --experimental_build_event_text_file=$TEST_log \
  pkg:output_files_and_tags || fail "bazel build failed"
  expect_log 'output_group'
  expect_log 'out1.txt'
  expect_log 'tag1'
  expect_log 'tag2'
}

function test_build_only() {
  # When building but not testing a test, there won't be a test summary
  # (as nothing was tested), so it should not be announced.
  # Still, no event should only be chained in by progress events.
  bazel build --experimental_build_event_text_file=$TEST_log pkg:true \
    || fail "bazel build failed"
  expect_not_log 'aborted'
  expect_not_log 'test_summary '
  expect_log_once '^progress'
  # Build Finished
  expect_log 'build_finished'
  expect_log 'overall_success: true'
  expect_log 'finish_time'
}

function test_build_test_suite() {
  # Sucessfully building a test suite should not have any unexpected events;
  # so we expect to see only one progress event.
  bazel build --experimental_build_event_text_file=$TEST_log pkg:suite \
    || fail "bazel build failed"
  expect_log_once '^progress'
}

function test_multiple_transports() {
  # Verifies usage of multiple build event transports at the same time
    outdir=$(mktemp -d ${TEST_TMPDIR}/bazel.XXXXXXXX)
    bazel test \
      --experimental_build_event_text_file=${outdir}/test_multiple_transports.txt \
      --experimental_build_event_binary_file=${outdir}/test_multiple_transports.bin \
      pkg:suite || fail "bazel test failed"
  [ -f ${outdir}/test_multiple_transports.txt ] || fail "Missing expected file test_multiple_transports.txt"
  [ -f ${outdir}/test_multiple_transports.bin ] || fail "Missing expected file test_multiple_transports.bin"
}

function test_root_cause_early() {
  (bazel build --experimental_build_event_text_file=$TEST_log \
         pkg:fails_to_build && fail "build failure expected") || true
  # We expect precisely one action being reported (the failed one) and
  # precisely on report on a completed target; moreover, the action has
  # to be reported first.
  expect_log_once '^action'
  expect_log_once '^completed'
  expect_not_log 'success'
  local naction=`grep -n '^action' $TEST_log | cut -f 1 -d :`
  local ncomplete=`grep -n '^completed' $TEST_log | cut -f 1 -d :`
  [ $naction -lt $ncomplete ] \
      || fail "failed action not before compelted target"
}

function test_loading_failure() {
  # Verify that if loading fails, this is properly reported as the
  # reason for the target expansion event not resulting in targets
  # being expanded.
  (bazel build --experimental_build_event_text_file=$TEST_log \
         //does/not/exist && fail "build failure expected") || true
  expect_log_once '^progress '
  expect_log_once '^loading_failed'
  expect_log 'details.*BUILD file not found on package path'
  expect_not_log 'expanded'
  expect_not_log 'aborted'
}

function test_loading_failure_keep_going() {
  (bazel build --experimental_build_event_text_file=$TEST_log \
         -k //does/not/exist && fail "build failure expected") || true
  expect_log_once '^loading_failed'
  expect_log_once '^expanded'
  expect_log 'details.*BUILD file not found on package path'
  expect_not_log 'aborted'
}

run_suite "Integration tests for the build event stream"
