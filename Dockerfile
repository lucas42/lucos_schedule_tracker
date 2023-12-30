FROM ruby:3.3.0-alpine3.18

WORKDIR /usr/src/app

COPY src/Gemfile .
RUN bundle install

COPY src/*.rb .

ENV PORT 8024
EXPOSE $PORT

CMD ["ruby", "server.rb"]
