```
.ztask # Location depends on the selected data directory path
  tasks/ # Default location for tasks, can be saved elsewhere
    <task_name1>.yml # Task file (YAML)
    <task_name2>.yml
  data/
    <task_id>/
      run_counter # Counter for amount of task runs
      meta.json  # Task file path, ID, name
      runs/
        <run_id>/
          meta.json # Run ID, start/end time, status, completed jobs
          jobs/
            <job_name>/
              meta.json # Job name, start/end time, status
              stdout.log # Output of executed commands/steps
```
