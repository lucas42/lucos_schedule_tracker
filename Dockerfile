FROM ruby:3-alpine

WORKDIR /usr/src/app

COPY *.rb .

ENV PORT 8024
EXPOSE $PORT

CMD ["ruby", "server.rb"]
