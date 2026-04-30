# lucos_schedule_tracker
Tracks the status of scheduled jobs

## Dependencies
* docker
* docker compose

## Build-time Dependencies (Installed by Dockerfile)
[Ruby 3](https://www.ruby-lang.org/en/)

## Running
`nice -19 docker compose up -d --no-build`

## Building
The build is configured to run in Dockerhub when a commit is pushed to the `main` branch in github.

## API Schema

`/report-status` Accepts a POST request with json encoded object containing the following fields:

* **`system`** The lucos system running the scheduled job.  (Must be unique - for systems with multiple jobs, append something to distinguish them)
* **`frequency`** A positive integer specifying how often the job should run, in seconds.  The alert threshold is derived server-side from `frequency` using a frequency-keyed rule:
  * `frequency < 4 days`: threshold = `frequency × 3`
  * `frequency ≥ 4 days`: threshold = `(frequency × 2) + 30 minutes`

  **Note on the step-change at the 4-day boundary:** a job at `frequency = 3 days 23h` gets a ~12-day threshold; bump it to `4 days` and it gets ~8.5 days. This is intentional — choose your frequency with this in mind if you are near the boundary.
* **`status`** The outcome of the scheduled job.  Accepts either "success" or "error".
* **`message`** [optional] An error message indicating why the job failed.  (ignored if status is "success")

cURL examples:

* `curl "http://localhost:8024/report-status" -H "Content-Type: application/json" -i --data '{"system":"lucos_test","frequency": 45,"status":"success","message":"Good Thing Happened"}'`
* `curl "http://localhost:8024/report-status" -H "Content-Type: application/json" -i --data '{"system":"lucos_test","frequency": 45,"status":"error","message":"Failure Happened"}'`

`/schedule/{system}` Accepts a DELETE request to remove a schedule entry from the tracker.

* Returns `204 No Content` whether or not the entry existed (idempotent).
* If the system later calls `/report-status` again, the entry will be re-created automatically.

cURL example:

* `curl -X DELETE "http://localhost:8024/schedule/lucos_test" -i`