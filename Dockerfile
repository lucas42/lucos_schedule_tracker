FROM ruby:3.3.5-alpine3.19

WORKDIR /usr/src/app

COPY src/Gemfile .
RUN bundle install

COPY src/*.rb .

ENV PORT 8024
EXPOSE $PORT

CMD ["ruby", "server.rb"]
