FROM resin/rpi-raspbian:jessie

# Install the dependencies
RUN apt-get update
RUN apt-get install python python-requests python-sh -y

# Add the current directoy in the container
ADD . /app

CMD python /app/resinhup.py --config /app/conf/resinhup --debug
