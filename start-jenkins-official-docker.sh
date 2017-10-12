JENKINS_DIR=~/jenkins_home

docker run -p 8080:8080 -p 50000:50000 -v $JENKINS_DIR:/var/jenkins_home jenkins/jenkins:lts