#!/usr/bin/env groovy

@Library("product-pipelines-shared-library") _

// Automated release, promotion and dependencies
properties([
  // Include the automated release parameters for the build
  release.addParams(),
  // Dependencies of the project that should trigger builds
  dependencies([])
])

// Performs release promotion.  No other stages will be run
if (params.MODE == "PROMOTE") {
  release.promote(params.VERSION_TO_PROMOTE) { infrapool, sourceVersion, targetVersion, assetDirectory ->
    runSecurityScans(infrapool,
        image: "registry.tld/conjur-action:${sourceVersion}-${git_commit(infrapool)}",
        buildMode: params.MODE,
        branch: env.BRANCH_NAME,
        arch: 'linux/amd64'
    )

    infrapool.agentGet from: "${assetDirectory}/", to: "./"

    signArtifacts patterns: ["*.tar.gz"]
    signArtifacts patterns: ["*.tar"]

    infrapool.agentPut from: "*.sig", to: "${assetDirectory}"

    echo "[DEBUG] Publishing to DockerHub"
    // NOTE: the use of --pull to ensure source images are pulled from internal registry
    infrapool.agentSh "./bin/publish_container_images --promote --pull --target ${targetVersion} --source ${sourceVersion}-${git_commit(infrapool)}"
    
    sh 'git config --global --add safe.directory "$(pwd)"'
  }

  release.copyEnterpriseRelease(params.VERSION_TO_PROMOTE)
  return
}

pipeline {
  agent { label 'conjur-enterprise-common-agent' }

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '30'))
    timeout(time: 1, unit: 'HOURS')
  }
  
  triggers {
    cron(getDailyCronString())
  }

  environment {
    // Sets the MODE to the specified or autocalculated value as appropriate
    MODE = release.canonicalizeMode()
  }

  stages {
    // Aborts any builds triggered by another project that wouldn't include any changes
    stage ("Skip build if triggering job didn't create a release") {
      when {
        expression {
          MODE == "SKIP"
        }
      }
      steps {
        script {
          currentBuild.result = 'ABORTED'
          error("Aborting build because this build was triggered from upstream, but no release was built")
        }
      }
    }

    stage('Scan for internal URLs') {
      steps {
        script {
          detectInternalUrls()
        }
      }
    }
    
    stage('Get InfraPool ExecutorV2 Agent') {
      steps {
        script {
          // Request ExecutorV2 agents for 1 hour(s)
          infrapool = getInfraPoolAgent.connected(type: "ExecutorV2", quantity: 1, duration: 1)[0]
        }
      }
    }

    stage('Validate Changelog') {
      steps { 
        script {
          parseChangelog(infrapool)
        }
      }
    }

    // Generates a VERSION file based on the current build number and latest version in CHANGELOG.md
    stage('Validate Changelog and set version') {
      steps {
        updateVersion(infrapool, "CHANGELOG.md", "${BUILD_NUMBER}")
      }
    }

    stage('Build Release Artifacts') {
      steps {
        script {
          infrapool.agentSh './bin/build_release'
          infrapool.agentSh './bin/publish_container_images --internal'
        }
      }
    }

    stage('Code Coverage') {
      steps {
        script {
          infrapool.agentSh './bin/coverage.sh'
          infrapool.agentStash name: 'junit-xml', includes: 'output/*.xml'
        }
      }
      post {
        always {
          unstash 'junit-xml'
          junit 'output/junit.xml'
          recordCoverage(
            tools: [[parser: 'COBERTURA', pattern: 'output/coverage.xml']],
            qualityGates: [
              [threshold: 30.0, metric: 'LINE',   baseline: 'PROJECT', unstable: true],
              [threshold: 30.0, metric: 'METHOD', baseline: 'PROJECT', unstable: true]
            ]
          )
          codacy action: 'reportCoverage', filePath: "output/coverage.xml"

        }
      }
    }

    stage('Run integration tests (Conjur OSS)') {
      steps {
        script {
          infrapool.agentSh './bin/start.sh'
        }
      }
    }

     stage('Run integration tests (Conjur Enterprise)') {
      steps {
        script {
          infrapool.agentSh './bin/start.sh -e'
        }
      }
    }

    stage('Run Conjur Cloud tests') {
      stages {
        stage('Create a Tenant') {
          steps {
            script {
              TENANT = getConjurCloudTenant()
            }
          }
        }
        stage('Authenticate') {
          steps {
            script {
              def id_token = getConjurCloudTenant.tokens(
                infrapool: infrapool,
                identity_url: "${TENANT.identity_information.idaptive_tenant_fqdn}",
                username: "${TENANT.login_name}"
              )

              def conj_token = getConjurCloudTenant.tokens(
                infrapool: infrapool,
                conjur_url: "${TENANT.conjur_cloud_url}",
                identity_token: "${id_token}"
                )

              env.conj_token = conj_token
            }
          }
        }
        stage('Run tests against Tenant') {
          environment {
            INFRAPOOL_CONJUR_APPLIANCE_URL="${TENANT.conjur_cloud_url}"
            INFRAPOOL_CONJUR_AUTHN_LOGIN="${TENANT.login_name}"
            INFRAPOOL_CONJUR_AUTHN_TOKEN="${env.conj_token}"
            INFRAPOOL_TEST_CLOUD=true
          }
          steps {
            script {
              infrapool.agentSh "./bin/start.sh -c"
            }
          }
        }
        stage('Get Edge Token') {
          steps {
            script {
              def edge_token = getConjurCloudTenant.tokens(
                infrapool: infrapool,
                conjur_url: "${TENANT.conjur_cloud_url}",
                edge_name: "${TENANT.conjur_edge_name}",
                conjur_token: "${conj_token}"
              )

              def deploy_edge = getConjurCloudTenant.edge(
                infrapool: infrapool,
                conjur_url: "${TENANT.conjur_cloud_url}",
                edge_name: "edge-test",
                edge_token: "${edge_token}",
                common_name: "edge-test",
                subject_alt_names: "edge-test"
              )
              
              env.edge_token = edge_token
            }
          }
        }
        stage('Run tests against Edge') {
          environment {
            INFRAPOOL_CONJUR_APPLIANCE_URL="${TENANT.conjur_cloud_url}"
            INFRAPOOL_CONJUR_AUTHN_LOGIN="${TENANT.login_name}"
            INFRAPOOL_CONJUR_AUTHN_TOKEN="${env.conj_token}"
            INFRAPOOL_TEST_CLOUD=true
          }
          steps {
            script {
              infrapool.agentSh "./bin/start.sh -ed"
            }
          }
        }
      }

      post {
        always {
          script {
            deleteConjurCloudTenant("${TENANT.id}")
          }
        }
      }
    }

    stage("Scan main Docker image") {
      steps {
        script {
          runSecurityScans(infrapool,
            image: "registry.tld/${containerImageWithTag(infrapool)}",
            buildMode: params.MODE,
            branch: env.BRANCH_NAME,
            arch: 'linux/amd64'
          )
        }
      }
    }

    stage('Release') {
      when {
        expression {
          MODE == "RELEASE"
        }
      }

      steps {
        script {
          release(infrapool) { billOfMaterialsDirectory, assetDirectory, toolsDirectory ->
            // Publish release artifacts to all the appropriate locations
            // Copy any artifacts to assetDirectory to attach them to the Github release
            infrapool.agentSh "cp conjur-action-*.tar.gz  ${assetDirectory}"
            infrapool.agentSh "cp conjur-action-*.tar  ${assetDirectory}"
          }
        }
      }
    }
  }
  post {
    always {
      releaseInfraPoolAgent(".infrapool/release_agents")
    }
  }
}


def containerImageWithTag(infrapool) {
  infrapool.agentSh(
    returnStdout: true,
    script: 'source ./bin/build_utils && echo "conjur-action:$(project_version_with_commit)"'
  )
}

def git_commit(infrapool) {
  infrapool.agentSh(
    returnStdout: true,
    script: 'source ./bin/build_utils && echo "$(git_commit)"'
  )
}


