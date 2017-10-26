# Jenkins in a Container, Running Jobs in Containers

Start Jenkins, ready to run Docker commands via the host's Docker, with this command:

`docker run -d -v /var/run/docker.sock:/var/run/docker.sock -v $(pwd):/var/jenkins_home -p 8080:8080 -p 50000:50000 jareddlc/jenkins-with-docker-socket`

You can build your own image that does this per the `Dockerfile-dockertools`