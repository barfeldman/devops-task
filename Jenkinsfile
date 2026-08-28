// Jenkins CI/CD pipeline for the sample Node.js app.
//
// Prerequisites on the Jenkins controller:
//   - Kubernetes plugin with a cloud configured (pods are the build agents).
//   - Credentials:
//       * 'regcred'            : a k8s Secret (kubernetes.io/dockerconfigjson) in
//                                the agent namespace, used to push images.
//       * 'github-credentials' : username + token (PAT) used to push GitOps commits.
//   - This Jenkinsfile is consumed by a Multibranch / "Pipeline from SCM" job so
//     that `checkout scm` and branch conditions work.
//
// Flow: test -> SAST -> dependency audit -> version bump -> build (Kaniko, no push)
//       -> image scan (Trivy, blocks on HIGH/CRITICAL) -> push (skopeo)
//       -> GitOps promotion (commit new image tag; ArgoCD reconciles).

pipeline {
  agent {
    kubernetes {
      defaultContainer 'node'
      yaml '''
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: sample-nodejs-ci
spec:
  volumes:
    - name: regcred
      secret:
        secretName: regcred
        items:
          - key: .dockerconfigjson
            path: config.json
  containers:
    - name: node
      image: node:22-alpine
      command: ["sleep"]
      args: ["infinity"]
    - name: git
      image: alpine/git:2.45.2
      command: ["sleep"]
      args: ["infinity"]
    - name: semgrep
      image: semgrep/semgrep:1.90.0
      command: ["sleep"]
      args: ["infinity"]
    - name: kaniko
      image: gcr.io/kaniko-project/executor:v1.23.2-debug
      command: ["sleep"]
      args: ["infinity"]
      volumeMounts:
        - name: regcred
          mountPath: /kaniko/.docker
    - name: trivy
      image: aquasec/trivy:0.55.0
      command: ["sleep"]
      args: ["infinity"]
    - name: skopeo
      image: quay.io/skopeo/stable:v1.16.1
      command: ["sleep"]
      args: ["infinity"]
      volumeMounts:
        - name: regcred
          mountPath: /skopeo/.docker
    - name: gitleaks
      image: ghcr.io/gitleaks/gitleaks:latest
      command: ["sleep"]
      args: ["infinity"]
    - name: hadolint
      image: hadolint/hadolint:2.12.0-alpine
      command: ["sleep"]
      args: ["infinity"]
    - name: helm
      image: alpine/helm:3.16.1
      command: ["sleep"]
      args: ["infinity"]
    - name: kubeconform
      image: ghcr.io/yannh/kubeconform:v0.6.7-alpine
      command: ["sleep"]
      args: ["infinity"]
'''
    }
  }

  options {
    timeout(time: 30, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20'))
    disableConcurrentBuilds()
  }

  environment {
    REGISTRY     = 'docker.io'
    IMAGE_NAME   = 'barfeldman/sample-nodejs'
    IMAGE        = "${REGISTRY}/${IMAGE_NAME}"
    APP_DIR      = 'app'
    CHART_DIR    = 'charts/sample-nodejs'
    GIT_REPO     = 'github.com/barfeldman/devops-task.git'
    CI_USER      = 'ci-bot'
    CI_EMAIL     = 'ci-bot@users.noreply.github.com'
  }

  stages {
    stage('Checkout') {
      steps {
        container('git') {
          checkout scm
          // Agent workspace is owned by a different UID than this container's
          // git; mark it safe so raw git commands don't abort (exit 128).
          sh 'git config --global --add safe.directory "*"'
          script {
            env.SHORT_SHA = sh(returnStdout: true, script: 'git rev-parse --short=7 HEAD').trim()
            def lastMsg   = sh(returnStdout: true, script: 'git log -1 --pretty=%B').trim()
            // Prevent an infinite loop from the GitOps promotion commit.
            if (lastMsg.contains('[skip ci]')) {
              currentBuild.result = 'NOT_BUILT'
              error('Skipping CI for [skip ci] commit')
            }
            // Default tag for PR/branch builds; overridden on main by Version Bump.
            env.IMAGE_TAG = "sha-${env.SHORT_SHA}"
          }
        }
      }
    }

    stage('Secret Scan') {
      steps {
        container('gitleaks') {
          // Fail the build if any secret is committed to the repo or its history.
          sh 'gitleaks detect --source=. --redact --exit-code=1 --report-format=sarif --report-path=gitleaks.sarif'
        }
      }
      post {
        always {
          archiveArtifacts artifacts: 'gitleaks.sarif', allowEmptyArchive: true
        }
      }
    }

    stage('Install & Test') {
      steps {
        container('node') {
          dir("${APP_DIR}") {
            sh 'npm ci'
            sh 'npm test'
          }
        }
      }
    }

    stage('SAST - Semgrep') {
      steps {
        container('semgrep') {
          // --error makes Semgrep exit non-zero on findings; --severity=ERROR
          // limits the gate to critical/high-severity rules.
          sh '''
            semgrep --version
            semgrep scan \
              --config=p/default \
              --config=p/nodejs \
              --config=p/javascript \
              --config=p/security-audit \
              --severity=ERROR \
              --error \
              --sarif --output=semgrep.sarif \
              "${APP_DIR}"
          '''
        }
      }
      post {
        always {
          archiveArtifacts artifacts: 'semgrep.sarif', allowEmptyArchive: true
        }
      }
    }

    stage('Dependency Audit') {
      steps {
        container('node') {
          dir("${APP_DIR}") {
            // Fail the build only on critical dependency vulnerabilities.
            sh 'npm audit --audit-level=critical'
          }
        }
      }
    }

    stage('Dockerfile Lint') {
      steps {
        container('hadolint') {
          sh 'hadolint "${APP_DIR}/Dockerfile"'
        }
      }
    }

    stage('Manifest Scan') {
      steps {
        container('helm') {
          sh 'helm template rel "${CHART_DIR}" --set vault.enabled=true > rendered-manifests.yaml'
        }
        container('trivy') {
          // Block on HIGH/CRITICAL Kubernetes misconfigurations.
          sh 'trivy config rendered-manifests.yaml --severity HIGH,CRITICAL --exit-code 1 --no-progress'
        }
        container('kubeconform') {
          // Schema-validate manifests; skip CRDs we don't ship schemas for.
          sh 'kubeconform -strict -summary -ignore-missing-schemas rendered-manifests.yaml'
        }
      }
    }

    stage('Version Bump') {
      when { branch 'main' }
      steps {
        container('node') {
          dir("${APP_DIR}") {
            script {
              def newVersion = sh(
                returnStdout: true,
                script: 'npm version patch --no-git-tag-version'
              ).trim().replaceFirst('^v', '')
              env.APP_VERSION = newVersion
              env.IMAGE_TAG   = "${newVersion}-${env.SHORT_SHA}"
            }
          }
        }
        echo "Release version ${env.APP_VERSION}  ->  image tag ${env.IMAGE_TAG}"
      }
    }

    stage('Build Image (Kaniko)') {
      steps {
        container('kaniko') {
          // Build to a tarball only; do NOT push yet. The image is pushed only
          // after Trivy clears it, so a vulnerable image never reaches the registry.
          sh '''
            /kaniko/executor \
              --context=dir://${WORKSPACE}/${APP_DIR} \
              --dockerfile=Dockerfile \
              --no-push \
              --tar-path=${WORKSPACE}/image.tar \
              --destination=${IMAGE}:${IMAGE_TAG}
          '''
        }
      }
    }

    stage('Image Scan (Trivy)') {
      steps {
        container('trivy') {
          // Gate: block the pipeline (and thus deployment) on HIGH/CRITICAL.
          sh '''
            trivy image \
              --input ${WORKSPACE}/image.tar \
              --scanners vuln \
              --severity HIGH,CRITICAL \
              --ignore-unfixed \
              --exit-code 1 \
              --no-progress \
              --format table
          '''
          // Non-failing machine-readable report for the record.
          sh '''
            trivy image --input ${WORKSPACE}/image.tar \
              --severity HIGH,CRITICAL --ignore-unfixed \
              --format json --output trivy-report.json || true
          '''
        }
      }
      post {
        always {
          archiveArtifacts artifacts: 'trivy-report.json', allowEmptyArchive: true
        }
      }
    }

    stage('Push Image (skopeo)') {
      when { branch 'main' }
      steps {
        container('skopeo') {
          sh '''
            skopeo copy --dest-authfile /skopeo/.docker/config.json \
              docker-archive:${WORKSPACE}/image.tar \
              docker://${IMAGE}:${IMAGE_TAG}
            skopeo copy \
              --src-authfile /skopeo/.docker/config.json \
              --dest-authfile /skopeo/.docker/config.json \
              docker://${IMAGE}:${IMAGE_TAG} \
              docker://${IMAGE}:latest
          '''
        }
      }
    }

    stage('Promote (GitOps)') {
      when { branch 'main' }
      steps {
        container('git') {
          withCredentials([usernamePassword(
              credentialsId: 'github-credentials',
              usernameVariable: 'GIT_USER',
              passwordVariable: 'GIT_TOKEN')]) {
            sh '''
              set -e
              git config user.name  "${CI_USER}"
              git config user.email "${CI_EMAIL}"

              # Promote the new image tag into the chart and bump chart appVersion.
              sed -i -E "s#^([[:space:]]*)tag:.*#\\1tag: \\"${IMAGE_TAG}\\"#" "${CHART_DIR}/values.yaml"
              sed -i -E "s#^appVersion:.*#appVersion: \\"${APP_VERSION}\\"#" "${CHART_DIR}/Chart.yaml"

              git add "${APP_DIR}/package.json" "${APP_DIR}/package-lock.json" \
                      "${CHART_DIR}/values.yaml" "${CHART_DIR}/Chart.yaml"
              git commit -m "ci: release v${APP_VERSION} (${IMAGE_TAG}) [skip ci]"
              git tag -a "v${APP_VERSION}" -m "Release v${APP_VERSION}"

              git push "https://${GIT_USER}:${GIT_TOKEN}@${GIT_REPO}" HEAD:main
              git push "https://${GIT_USER}:${GIT_TOKEN}@${GIT_REPO}" "v${APP_VERSION}"
            '''
          }
        }
      }
    }
  }

  post {
    success {
      echo "Pipeline succeeded. Image: ${env.IMAGE}:${env.IMAGE_TAG}"
    }
    failure {
      echo 'Pipeline failed - see stage logs above.'
    }
  }
}
