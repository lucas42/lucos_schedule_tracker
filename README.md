# lucos_schedule_tracker
Tracks the status of scheduled jobs

## Dependencies
* docker
* docker-compose

## Build-time Dependencies (Installed by Dockerfile)
[Ruby 3](https://www.ruby-lang.org/en/)

## Running
`nice -19 docker-compose up -d --no-build`

## Building
The build is configured to run in Dockerhub when a commit is pushed to the master branch in github.