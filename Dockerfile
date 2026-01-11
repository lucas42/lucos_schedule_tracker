FROM ruby:3.3.6-alpine3.19

WORKDIR /usr/src/app

COPY src/Gemfile .
RUN bundle install

COPY src/*.rb .

CMD ["ruby", "server.rb"]
