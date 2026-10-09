function plan = buildfile
import matlab.buildtool.tasks.*

plan = buildplan(localfunctions);

addpath("source")

plan("clean") = CleanTask;
plan("check") = CodeIssuesTask(Results="code-issues/results.sarif");
plan("test") = TestTask("tests", ...
    SourceFiles="source", ...
    TestResults="test-results/results.xml", ...
    CodeCoverageResults="code-coverage/results.xml");

% Tasks used by the cache bash workflows. They are not default tasks.
plan("probe").Inputs = "source";
plan("probe").Outputs = "probe-out/probe.txt";
plan("stamp").Inputs = "source";

plan.DefaultTasks = ["check" "test"];
end

function probeTask(context)
% Has inputs and outputs, so it can be skipped only if its outputs exist or are restored from the output cache
recordRun("probe")
out = context.Task.Outputs.paths;
[~] = mkdir(fileparts(out));
writelines(string(datetime("now")),out)
end

function stampTask(~)
% Has inputs but no outputs, so a restored .buildtool trace alone is enough to skip it
recordRun("stamp")
end

function failTask(~)
% Has no inputs or outputs, so it always runs; used to inject a build failure
error("bash:InjectedFailure","Injected failure for cache bashing.")
end

function recordRun(name)
% Appends the task name to BASH_RUN_LOG so workflows can tell whether the task action executed
log = getenv("BASH_RUN_LOG");
if log ~= ""
    writelines(name,log,WriteMode="append")
end
end
