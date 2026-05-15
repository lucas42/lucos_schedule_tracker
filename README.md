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

### v2 API (current)

`/v2/report-status` Accepts a POST request with a JSON-encoded object. Supports tracking multiple named jobs per system.

* **`system`** *(required)* The lucos system running the scheduled job (e.g. `"lucos_arachne"`).
* **`job_name`** *(required)* A non-empty string identifying the specific job within the system (e.g. `"ingestor_dbpedia"`). Must not be empty or null. Use a descriptive name even for single-job systems — it simplifies adding further jobs later.
* **`frequency`** *(required)* A positive integer specifying how often the job should run, in seconds. The alert threshold is derived server-side using a frequency-keyed rule:
  * `frequency < 4 days`: threshold = `frequency × 3`
  * `frequency ≥ 4 days`: threshold = `(frequency × 2) + 30 minutes`

  **Note on the step-change at the 4-day boundary:** a job at `frequency = 3 days 23h` gets a ~12-day threshold; bump it to `4 days` and it gets ~8.5 days. This is intentional — choose your frequency with this in mind if you are near the boundary.
* **`status`** *(required)* The outcome of the scheduled job. Accepts `"success"` or `"error"`.
* **`message`** *(optional)* An error message indicating why the job failed. Ignored if status is `"success"`.

Returns `400 Bad Request` if `job_name` is missing, empty, null, or not a string.

cURL examples:

* `curl "http://localhost:8024/v2/report-status" -H "Content-Type: application/json" -i --data '{"system":"lucos_arachne","job_name":"ingestor_dbpedia","frequency":86400,"status":"success"}'`
* `curl "http://localhost:8024/v2/report-status" -H "Content-Type: application/json" -i --data '{"system":"lucos_arachne","job_name":"ingestor_dbpedia","frequency":86400,"status":"error","message":"Timeout"}'`

`/v2/schedule/{system}/{job_name}` Accepts a DELETE request to remove a specific job entry from the tracker.

* Returns `204 No Content` whether or not the entry existed (idempotent).

cURL example:

* `curl -X DELETE "http://localhost:8024/v2/schedule/lucos_arachne/ingestor_dbpedia" -i`

`/jobs` Returns a JSON array of all tracked jobs with their current status, metrics, and alert state.

### Retired v1 API

`POST /report-status` is retired and returns `410 Gone`. All callers must migrate to `POST /v2/report-status`.
See [ADR-0004](https://github.com/lucas42/lucos/blob/main/docs/adr/0004-scheduled-jobs-monitoring-architecture.md) for the migration guide.

`DELETE /schedule/{system}` remains available for removing legacy v1 rows with an empty `job_name` (e.g. during post-migration cleanup). Once all v1 rows are deleted, this endpoint is effectively a no-op.