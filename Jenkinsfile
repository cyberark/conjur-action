#!/usr/bin/env groovy

pipeline {
  agent { label 'conjur-enterprise-common-agent' }

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }
  
  triggers {
    cron(getDailyCronString())
  }

  stages {
    // stage('Validate') {
    //   parallel {
    //     stage('Changelog') {
    //       steps { sh './bin/parse-changelog.sh' }
    //     }
    //   }
    // }

    stage('Get InfraPool ExecutorV2 Agent') {
      steps {
        script {
          // Request ExecutorV2 agents for 1 hour(s)
          INFRAPOOL_EXECUTORV2_AGENT_0 = getInfraPoolAgent.connected(type: "ExecutorV2", quantity: 1, duration: 1)[0]
        }
      }
    }

    stage('Build Release Artifacts') {

      steps {
        script {
          INFRAPOOL_EXECUTORV2_AGENT_0.agentSh './bin/build_release'
          INFRAPOOL_EXECUTORV2_AGENT_0.agentArchiveArtifacts artifacts: 'conjur-action-*.tar.gz'
        }
      }
    }

    
  }

  post {
    always {
      script {
        releaseInfraPoolAgent(".infrapool/release_agents")
      }
    }
  }
}
