# Use an official Python runtime as a parent image
FROM python:3.11

WORKDIR /app

COPY . /app

RUN pip install requests

RUN chmod +x /app/wrapper.sh

CMD ["./wrapper.sh"]

