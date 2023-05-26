#!/usr/bin/env groovy

pipeline {
  agent { label 'executor-v2' }

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  stages {
    // stage('Validate') {
    //   parallel {
    //     stage('Changelog') {
    //       steps { sh './bin/parse-changelog.sh' }
    //     }
    //   }
    // }

    stage('Build Release Artifacts') {

      steps {
        sh './bin/build_release'
        archiveArtifacts '/output/conjur-action-*.tar.gz'
      }
    }

    
  }

  post {
    always {
      cleanupAndNotify(currentBuild.currentResult)
    }
  }
}