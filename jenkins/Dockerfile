FROM jenkins/jenkins:lts-jdk17

USER root

# Install Python 3 so Jenkins can run python/pytest directly
RUN apt-get update && \
    apt-get install -y python3 python3-pip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

USER jenkins

ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"
ENV CASC_JENKINS_CONFIG="/usr/share/jenkins/ref/casc.yaml"

# Install plugins
COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Copy Configuration as Code
COPY --chown=jenkins:jenkins casc.yaml /usr/share/jenkins/ref/casc.yaml
