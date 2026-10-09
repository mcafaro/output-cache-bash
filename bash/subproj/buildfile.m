function plan = buildfile
% Minimal build used to exercise caching with the -sd startup option
plan = buildplan(localfunctions);
plan("probe").Inputs = "source";
plan("probe").Outputs = "probe-out/probe.txt";
end

function probeTask(context)
log = getenv("BASH_RUN_LOG");
if log ~= ""
    writelines("probe",log,WriteMode="append")
end
out = context.Task.Outputs.paths;
[~] = mkdir(fileparts(out));
writelines(string(datetime("now")),out)
end
