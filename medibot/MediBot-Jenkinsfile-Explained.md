# MediBot — Jenkinsfile Explained
### A stage-by-stage, beginner-friendly walkthrough of the entire CI pipeline

> This explains every single line of the real `Jenkinsfile` in the
> `medibot-app` repo — what each stage does, exactly which secret or
> credential it uses and where that credential was originally created,
> which Jenkins plugin makes each piece of syntax possible, and what
> breaks (and how) if any one piece is missing or misconfigured.

---

## Table of Contents

1. [What a Jenkinsfile Actually Is](#1-what-a-jenkinsfile-actually-is)
2. [The Full File, For Reference](#2-the-full-file-for-reference)
3. [The `pipeline {}` Block's Top-Level Keys](#3-the-pipeline--blocks-top-level-keys)
4. [The `environment {}` Block, Line by Line](#4-the-environment--block-line-by-line)
5. [Every Stage, In Full Detail](#5-every-stage-in-full-detail)
6. [Master Credentials Table](#6-master-credentials-table)
7. [Master Plugin Table](#7-master-plugin-table)
8. [The Groovy String Quoting Trap — Read This Once](#8-the-groovy-string-quoting-trap--read-this-once)
9. [What Triggers This Pipeline, End to End](#9-what-triggers-this-pipeline-end-to-end)
10. [General Beginner FAQ](#10-general-beginner-faq)

---

## 1. What a Jenkinsfile Actually Is

A `Jenkinsfile` is a text file, committed to your source repo
(`medibot-app`, at the root), written in a Jenkins-specific DSL
("Domain Specific Language") that's actually built on top of the
**Groovy** programming language. You don't need to know Groovy to
follow this project's Jenkinsfile — it uses the simpler **Declarative
Pipeline** style (the `pipeline { ... }` wrapper), which looks and
reads almost like structured configuration rather than a real
program, even though Groovy is genuinely running underneath it.

**Why keep this in the source repo instead of configuring stages by
clicking through the Jenkins UI?** This is "Pipeline as Code" — the
entire build process is version-controlled, reviewable in a pull
request, and identical no matter which Jenkins server runs it. The
main setup guide's Phase 14, Step 46 configures the Jenkins job to
read this exact file (`Script Path: Jenkinsfile`) directly from the
repo on every run, instead of a human maintaining separate
click-through configuration inside Jenkins itself.

**How Jenkins actually finds and runs it, each time:**

1. A push lands on `medibot-app`'s `main` branch.
2. GitHub's webhook (configured in Step 47) notifies Jenkins.
3. Jenkins' `medibot-ci` job (configured in Step 46) re-clones the repo.
4. Jenkins reads the `Jenkinsfile` at the repo root and parses the
   `pipeline { }` block.
5. It runs each `stage` inside, **strictly in the order they're
   written**, top to bottom — this file has no parallel stages, so
   each one fully finishes (or fails) before the next one starts.

---

## 2. The Full File, For Reference

```groovy
pipeline {
    agent any

    tools {
        maven 'maven3'
    }

    environment {
        JAVA_HOME      = '/usr/lib/jvm/java-17-openjdk-amd64'
        PATH           = "${JAVA_HOME}/bin:${env.PATH}"
        SCANNER_HOME   = tool 'sonar-scanner'
        IMAGE_TAG      = "v${BUILD_NUMBER}"
        AWS_ACCOUNT_ID = credentials('aws-account-id')
        AWS_REGION     = 'ap-south-1'
        ECR_REGISTRY   = "${AWS_ACCOUNT_ID}.dkr.ecr.ap-south-1.amazonaws.com"
        ECR_REPO       = 'medibot'
        IMAGE_FULL     = "${AWS_ACCOUNT_ID}.dkr.ecr.ap-south-1.amazonaws.com/medibot"
    }

    stages {
        stage('Git Checkout') {
            steps {
                git branch: 'main',
                    credentialsId: 'git',
                    url: 'https://github.com/nihitkumar78/medibot-app.git'
            }
        }

        stage('Compile') {
            steps {
                sh 'mvn compile'
            }
        }

        stage('Test') {
            steps {
                sh 'mvn test'
            }
        }

        stage('Trivy FS Scan') {
            steps {
                sh 'trivy fs --format table -o trivy-fs-report.html .'
            }
        }

        stage('SonarQube Analysis') {
            steps {
                withSonarQubeEnv('sonar') {
                    sh '''
                        $SCANNER_HOME/bin/sonar-scanner \
                        -Dsonar.projectKey=medibot \
                        -Dsonar.projectName=medibot \
                        -Dsonar.java.binaries=target
                    '''
                }
            }
        }

        stage('Quality Gate') {
            steps {
                timeout(time: 1, unit: 'HOURS') {
                    waitForQualityGate abortPipeline: false,
                                       credentialsId: 'sonar-token'
                }
            }
        }

        stage('Build JAR') {
            steps {
                sh 'mvn package -DskipTests'
            }
        }

        stage('Publish to Nexus') {
            steps {
                withMaven(globalMavenSettingsConfig: 'medibot-nexus',
                          maven: 'maven3',
                          traceability: true) {
                    sh 'mvn deploy -DskipTests'
                }
            }
        }

        stage('Docker Build') {
            steps {
                sh "docker build -t ${ECR_REPO}:${IMAGE_TAG} ."
            }
        }

        stage('Trivy Image Scan') {
            steps {
                sh "trivy image --format table -o trivy-image-report.html ${ECR_REPO}:${IMAGE_TAG}"
            }
        }

        stage('Push to ECR') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding',
                                   credentialsId: 'aws-creds']]) {
                    sh '''
                        aws ecr get-login-password --region ${AWS_REGION} | \
                        docker login --username AWS --password-stdin ${ECR_REGISTRY}

                        docker tag ${ECR_REPO}:${IMAGE_TAG} ${IMAGE_FULL}:${IMAGE_TAG}
                        docker push ${IMAGE_FULL}:${IMAGE_TAG}

                        docker tag ${ECR_REPO}:${IMAGE_TAG} ${IMAGE_FULL}:latest
                        docker push ${IMAGE_FULL}:latest
                    '''
                }
            }
        }

        stage('Update Manifests Repo') {
            steps {
                script {
                    cleanWs()
                    withCredentials([usernamePassword(
                            credentialsId: 'git',
                            usernameVariable: 'GIT_USER',
                            passwordVariable: 'GIT_PASS')]) {
                        sh '''
                            git clone https://${GIT_USER}:${GIT_PASS}@github.com/nihitkumar78/medibot-manifests.git
                            cd medibot-manifests

                            sed -i "s|image:.*medibot:.*|image: ${IMAGE_FULL}:${IMAGE_TAG}|g" deployment.yaml

                            git config user.name "Jenkins"
                            git config user.email "jenkins@medibot.com"
                            git add deployment.yaml
                            git commit -m "Update image to ${IMAGE_TAG} [build #${BUILD_NUMBER}]"
                            git push origin main
                        '''
                    }
                }
            }
        }
    }
}
```

---

## 3. The `pipeline {}` Block's Top-Level Keys

```groovy
pipeline {
    agent any

    tools {
        maven 'maven3'
    }
    ...
}
```

| Key | Meaning |
|---|---|
| `pipeline { }` | The outer wrapper that marks this whole file as a **Declarative Pipeline** (as opposed to the older, more free-form "Scripted Pipeline" style) — everything inside follows a fixed, predictable structure. |
| `agent any` | Tells Jenkins *where* to actually run this pipeline's steps — `any` means "run on whatever executor is available," which in this project's setup is the Jenkins EC2 instance itself (there's no separate pool of build agents configured — Jenkins is both the controller and the only worker). Every `sh` command in every stage literally runs as a shell command on this one EC2 box. |
| `tools { maven 'maven3' }` | **[LINK]** `'maven3'` must exactly match the name given to a Maven installation configured under **Manage Jenkins → Tools** (set up in the main setup guide's Phase 10, Step 33). This line tells Jenkins "before running any stage, make sure this named Maven installation is available, and add its `bin/` directory to `PATH` for the rest of this pipeline" — this is *why* plain `sh 'mvn compile'` works later without ever specifying a path to `mvn`. Requires the **Maven Integration** plugin. |

---

## 4. The `environment {}` Block, Line by Line

```groovy
environment {
    JAVA_HOME      = '/usr/lib/jvm/java-17-openjdk-amd64'
    PATH           = "${JAVA_HOME}/bin:${env.PATH}"
    SCANNER_HOME   = tool 'sonar-scanner'
    IMAGE_TAG      = "v${BUILD_NUMBER}"
    AWS_ACCOUNT_ID = credentials('aws-account-id')
    AWS_REGION     = 'ap-south-1'
    ECR_REGISTRY   = "${AWS_ACCOUNT_ID}.dkr.ecr.ap-south-1.amazonaws.com"
    ECR_REPO       = 'medibot'
    IMAGE_FULL     = "${AWS_ACCOUNT_ID}.dkr.ecr.ap-south-1.amazonaws.com/medibot"
}
```

Everything defined here becomes a **shell environment variable**
available in every single stage below, for the entire duration of this
pipeline run. Think of this block as "set these once, up front, so I
don't have to repeat them in every stage."

| Line | Meaning |
|---|---|
| `JAVA_HOME = '/usr/lib/jvm/java-17-openjdk-amd64'` | A **single-quoted** Groovy string — a plain, literal value, no interpolation happens. This overrides, *just for this pipeline's own processes*, which Java installation gets used — specifically so Maven compiles with Java 17 (what this app's `pom.xml` requires) even though the Jenkins service itself runs on Java 21 system-wide. See [Section 8](#8-the-groovy-string-quoting-trap--read-this-once) for exactly why this distinction matters, and the main setup guide's Phase 7, Step 18 for the full story of the bug this fixes. |
| `PATH = "${JAVA_HOME}/bin:${env.PATH}"` | A **double-quoted** Groovy string — this one *does* get interpolated by Groovy itself, before the shell ever runs anything. `${JAVA_HOME}` refers to the variable defined on the line directly above; `${env.PATH}` refers to the *existing* system PATH Jenkins already had. The result: this pipeline's `PATH` becomes "Java 17's `bin` folder, followed by everything that was already on PATH" — so when a later stage runs plain `java` or relies on Maven internally invoking `java`, it finds the Java 17 binary first. |
| `SCANNER_HOME = tool 'sonar-scanner'` | **[LINK]** `tool` is a built-in Jenkins pipeline function that looks up a named tool installation and returns its filesystem path. `'sonar-scanner'` must exactly match the name configured under **Manage Jenkins → Tools → SonarQube Scanner installations** (main guide Phase 10, Step 33). Requires the **SonarQube Scanner** plugin. |
| `IMAGE_TAG = "v${BUILD_NUMBER}"` | `BUILD_NUMBER` is a variable Jenkins provides automatically for every job — an integer that increments by 1 on every single run of this job, forever (1, 2, 3, ...). This line just prefixes it with `v`, giving tags like `v1`, `v2`, `v8`, etc. — this is *why* your ECR repo accumulates a growing list of versioned images over time. |
| `AWS_ACCOUNT_ID = credentials('aws-account-id')` | **[LINK, credential]** The `credentials()` helper function looks up a Jenkins Credential by its ID and injects its value as a plain environment variable — in this case a **Secret Text** credential, with ID `aws-account-id`, created in the main setup guide's Phase 10, Step 34, holding the literal string `719152986284`. Jenkins also automatically masks this value in console logs (replacing it with `****`) anywhere it would otherwise be printed — though for a non-sensitive value like an account ID, that masking is mostly a side-effect of using the same mechanism as real secrets, not a strict requirement. |
| `AWS_REGION = 'ap-south-1'` | A plain, hardcoded literal — no lookup, no interpolation, just a fixed string. |
| `ECR_REGISTRY = "${AWS_ACCOUNT_ID}.dkr.ecr.ap-south-1.amazonaws.com"` | Double-quoted, interpolated — builds the full ECR registry hostname by combining the account ID (from the credential above) with the fixed region. |
| `ECR_REPO = 'medibot'` | A plain, hardcoded literal — the name of the ECR repository created in the main setup guide's Phase 6. |
| `IMAGE_FULL = "${AWS_ACCOUNT_ID}.dkr.ecr.ap-south-1.amazonaws.com/medibot"` | The complete, pushable image reference: registry + repository, with no tag yet (the tag gets appended per-use later, e.g. `${IMAGE_FULL}:${IMAGE_TAG}`). |

---

## 5. Every Stage, In Full Detail

### Stage 1 — `Git Checkout`

```groovy
stage('Git Checkout') {
    steps {
        git branch: 'main',
            credentialsId: 'git',
            url: 'https://github.com/nihitkumar78/medibot-app.git'
    }
}
```

**What it does:** explicitly clones the `main` branch of `medibot-app`
into Jenkins' workspace for this build. (Jenkins actually performs an
*implicit* checkout automatically before any stage even runs, because
the job itself is configured as "Pipeline script from SCM" — this
explicit `git` step is a second, deliberate checkout matching the
exact same repo, kept here for clarity/explicitness about exactly
which repo and branch this pipeline builds from.)

**Credential used:** `git` (Username with Password kind) — created in
the main setup guide's Phase 10, Step 34, holding your GitHub username
and the Personal Access Token from Phase 1, Step 2. Required because
`medibot-app` is a **private** repo — without valid credentials, this
clone fails outright with an authentication error.

**Plugin required:** none beyond Jenkins' built-in Git support (the
core **Git plugin**, which ships by default in any standard Jenkins
install).

**If this fails:** the entire pipeline stops immediately — nothing
downstream can run without the source code.

---

### Stage 2 — `Compile`

```groovy
stage('Compile') {
    steps {
        sh 'mvn compile'
    }
}
```

**What it does:** runs `mvn compile` — Maven downloads all dependencies
listed in `pom.xml` (Spring Boot, the AWS Bedrock SDK, MySQL connector,
Jackson, etc.) and compiles all Java source files into `.class` files
under `target/`. No tests run yet, nothing gets packaged yet — this
stage exists purely to catch compilation errors as early as possible,
before spending time on anything else.

**Why this is where the Java 17 vs. 21 bug showed up:** this is the
*first* stage that actually invokes the `java`/`javac` toolchain — if
`JAVA_HOME` weren't correctly scoped to Java 17 (Section 4), this is
exactly where you'd see `error: release version 17 not supported`.

**Credential used:** none.

**Plugin required:** none beyond the Maven Integration plugin already
covered by the `tools {}` block.

---

### Stage 3 — `Test`

```groovy
stage('Test') {
    steps {
        sh 'mvn test'
    }
}
```

**What it does:** runs any unit tests defined under
`src/test/java` using the `spring-boot-starter-test` dependency from
`pom.xml`. If any test fails, Maven exits with a non-zero status, which
fails this stage and stops the pipeline.

**Credential used:** none. **Plugin required:** none additional.

---

### Stage 4 — `Trivy FS Scan`

```groovy
stage('Trivy FS Scan') {
    steps {
        sh 'trivy fs --format table -o trivy-fs-report.html .'
    }
}
```

**What it does:** runs Trivy (installed directly on the Jenkins EC2 in
the main setup guide's Phase 7, Step 20 — **not** a Jenkins plugin,
just a CLI binary invoked via `sh`) against the entire checked-out
filesystem (`.`), scanning for known-vulnerable dependencies listed in
`pom.xml` and any other flagged filesystem-level issues. Writes a
human-readable HTML report (`trivy-fs-report.html`) into the workspace.

**Note:** this stage does **not** fail the build on findings by
default (no `--exit-code` flag is set) — it's informational only in
this configuration. A stricter setup would add `--exit-code 1` to
actually block the pipeline on critical vulnerabilities.

**Credential used:** none. **Plugin required:** none — Trivy is a
plain shell command, not a Jenkins integration.

---

### Stage 5 — `SonarQube Analysis`

```groovy
stage('SonarQube Analysis') {
    steps {
        withSonarQubeEnv('sonar') {
            sh '''
                $SCANNER_HOME/bin/sonar-scanner \
                -Dsonar.projectKey=medibot \
                -Dsonar.projectName=medibot \
                -Dsonar.java.binaries=target
            '''
        }
    }
}
```

**What it does:** submits the compiled code to SonarQube for static
analysis (bugs, code smells, security hotspots, duplication, test
coverage if configured).

**`withSonarQubeEnv('sonar')`:** this wraps the enclosed step with
connection details for a SonarQube server — specifically, the one
named `sonar` under **Manage Jenkins → System → SonarQube servers**
(main setup guide Phase 10, Step 35), which holds the SonarQube
server's URL and its authentication token credential. **[LINK]** The
string `'sonar'` here must exactly match that configured server's
name — this single name is what connects this stage to the right
SonarQube instance and its stored token, without the token ever
appearing directly in this file.

**`$SCANNER_HOME/bin/sonar-scanner`:** runs the actual scanner binary,
whose location was resolved earlier by `tool 'sonar-scanner'` in the
`environment {}` block.

**`-Dsonar.projectKey` / `-Dsonar.projectName`:** identifies this
project inside SonarQube's own UI — must match (or SonarQube creates a
new project entry) the project you're viewing results for.

**`-Dsonar.java.binaries=target`:** tells SonarQube's Java analyzer
where to find the already-compiled `.class` files (from Stage 2) — the
Java analyzer needs real bytecode, not just source, to run certain
checks.

**Credential used:** indirectly, the SonarQube server's own stored
authentication token (configured once, server-wide, in Step 35 — not a
separate credential referenced per-build here).

**Plugin required:** **SonarQube Scanner** plugin (provides both the
`withSonarQubeEnv` step and the `tool 'sonar-scanner'` installation
type).

**If this fails:** usually an authentication problem with the
SonarQube server connection, or the SonarQube server being unreachable
(check the IP hasn't changed — see the main guide's IP Address
Dependencies section).

---

### Stage 6 — `Quality Gate`

```groovy
stage('Quality Gate') {
    steps {
        timeout(time: 1, unit: 'HOURS') {
            waitForQualityGate abortPipeline: false,
                               credentialsId: 'sonar-token'
        }
    }
}
```

**What it does, and why it's a completely separate stage from the
analysis itself:** Stage 5 only *submits* code for analysis — SonarQube
processes it asynchronously in the background, which can take anywhere
from a few seconds to a minute or more. This stage *pauses the
pipeline* and waits for SonarQube to report back a pass/fail verdict
("Quality Gate" status) for that analysis.

**How the wait actually ends:** not by polling — by a **webhook**.
SonarQube, once it finishes analyzing, calls a webhook URL configured
back in the main setup guide's Phase 8, Step 26
(`http://<jenkins_ip>:8080/sonarqube-webhook/`) to say "analysis done,
here's the result." That webhook call is what unblocks this
`waitForQualityGate` step. **Without that webhook configured
correctly, this stage hangs for the full `timeout` duration (1 hour)
and then fails** — a very common, very confusing failure mode, because
the actual root cause (a missing/wrong webhook URL, or a missing
trailing slash) is configured over in SonarQube's own UI, nowhere near
this Jenkinsfile.

**`abortPipeline: false`:** even if the Quality Gate fails (code didn't
meet SonarQube's quality thresholds), the pipeline is told to *continue
anyway* rather than stop — meaning in this project's current
configuration, a failing Quality Gate is informational only and never
actually blocks a deployment. (Setting this to `true` would make a
failing gate stop the whole pipeline.)

**Credential used:** `sonar-token` (Secret Text kind) — created in
Phase 10, Step 34, holding the SonarQube analysis token generated back
in Phase 8, Step 26.

**Plugin required:** **SonarQube Scanner** plugin (provides
`waitForQualityGate`).

---

### Stage 7 — `Build JAR`

```groovy
stage('Build JAR') {
    steps {
        sh 'mvn package -DskipTests'
    }
}
```

**What it does:** runs `mvn package`, which compiles (again, Maven is
incremental but re-verifies), and this time actually produces the
final build artifact — a runnable `.jar` file under `target/`, thanks
to the `spring-boot-maven-plugin` declared in `pom.xml`'s `<build>`
section (that plugin repackages a plain Spring JAR into an
"executable" one with an embedded web server).

**`-DskipTests`:** deliberately skips re-running the test suite here —
it already ran in Stage 3, so this avoids doing redundant work.

**Credential used:** none. **Plugin required:** none additional.

---

### Stage 8 — `Publish to Nexus`

```groovy
stage('Publish to Nexus') {
    steps {
        withMaven(globalMavenSettingsConfig: 'medibot-nexus',
                  maven: 'maven3',
                  traceability: true) {
            sh 'mvn deploy -DskipTests'
        }
    }
}
```

**What it does:** runs `mvn deploy`, which — unlike `package` — doesn't
just build the JAR locally, it **uploads** it to a remote Maven
repository, specifically the Nexus repositories (`medibot-releases` /
`medibot-snapshots`) declared in `pom.xml`'s `<distributionManagement>`
section.

**`withMaven(globalMavenSettingsConfig: 'medibot-nexus', ...)`:**
**[LINK]** this is the key piece — `mvn deploy` needs to *authenticate*
to Nexus, and that authentication lives in a Maven `settings.xml` file,
**not** in `pom.xml` (which only has the repository *URLs*, not
credentials — see the manifests/pom.xml split explained in the main
setup guide's Phase 9, Step 29). `globalMavenSettingsConfig: 'medibot-nexus'`
tells Jenkins to inject the **Managed File** with that exact ID
(created in Phase 10, Step 36) as the `settings.xml` used for this
one Maven invocation — that file is where the Nexus username/password
actually lives, matched up to `pom.xml`'s repository `<id>` tags.

**`traceability: true`:** adds extra console-log detail about exactly
which configuration files Jenkins injected for this step — purely a
debugging aid, doesn't change behavior.

**Credential used:** indirectly, the Nexus `jenkins` user's password,
embedded inside the `medibot-nexus` Managed File (not a traditional
Jenkins Credential object — Managed Files are a separate but related
mechanism, provided by the same **Config File Provider** plugin).

**Plugin required:** **Pipeline Maven Integration** plugin (provides
the `withMaven` step) and **Config File Provider** plugin (provides
Managed Files like `medibot-nexus`).

**If this fails with a 401:** the password inside the `medibot-nexus`
Managed File doesn't match the actual password set for the `jenkins`
user in Nexus's own UI — these two have to be kept in sync manually,
there's no automatic link between them.

---

### Stage 9 — `Docker Build`

```groovy
stage('Docker Build') {
    steps {
        sh "docker build -t ${ECR_REPO}:${IMAGE_TAG} ."
    }
}
```

**What it does:** builds a Docker image from the `Dockerfile` at the
repo root, tagging it locally as `medibot:v<build-number>` (both
`ECR_REPO` and `IMAGE_TAG` come from the `environment {}` block,
Section 4). This is a **double-quoted** `sh` string, so Groovy
interpolates `${ECR_REPO}` and `${IMAGE_TAG}` itself, before the shell
ever sees the command — see [Section 8](#8-the-groovy-string-quoting-trap--read-this-once)
for exactly why this matters.

**Why this works without extra Docker setup:** the Jenkins EC2 itself
has Docker installed directly on it (main setup guide Phase 7, Step 19),
and the `jenkins` system user was added to the `docker` group during
that same step — `sh` here just runs a completely ordinary shell
command against the host's own Docker daemon, no Docker-in-Docker or
remote Docker API involved.

**Credential used:** none. **Plugin required:** **Docker** and
**Docker Pipeline** plugins (technically the raw `sh "docker build..."`
command would work even without these plugins installed, since it's
just a shell call — but these plugins are what the main setup guide
installs to support richer, alternative Docker syntax elsewhere in
Jenkins' ecosystem; this project sticks to the simpler `sh` approach
throughout).

---

### Stage 10 — `Trivy Image Scan`

```groovy
stage('Trivy Image Scan') {
    steps {
        sh "trivy image --format table -o trivy-image-report.html ${ECR_REPO}:${IMAGE_TAG}"
    }
}
```

**What it does:** scans the Docker image *just built* (not the
filesystem this time — the actual container image, including its base
OS layer and all installed packages) for known vulnerabilities, writing
a report to `trivy-image-report.html`. Same as Stage 4, this doesn't
block the pipeline on findings in the current configuration.

**Credential used:** none. **Plugin required:** none — plain CLI call.

---

### Stage 11 — `Push to ECR`

```groovy
stage('Push to ECR') {
    steps {
        withCredentials([[$class: 'AmazonWebServicesCredentialsBinding',
                           credentialsId: 'aws-creds']]) {
            sh '''
                aws ecr get-login-password --region ${AWS_REGION} | \
                docker login --username AWS --password-stdin ${ECR_REGISTRY}

                docker tag ${ECR_REPO}:${IMAGE_TAG} ${IMAGE_FULL}:${IMAGE_TAG}
                docker push ${IMAGE_FULL}:${IMAGE_TAG}

                docker tag ${ECR_REPO}:${IMAGE_TAG} ${IMAGE_FULL}:latest
                docker push ${IMAGE_FULL}:latest
            '''
        }
    }
}
```

**What it does, in order:**
1. `aws ecr get-login-password` asks AWS for a short-lived (12-hour)
   authentication token for ECR, and pipes it directly into
   `docker login` — this is the AWS-recommended way to authenticate
   Docker to a private ECR registry, avoiding ever typing or storing a
   long-lived Docker password.
2. Tags the locally-built image (from Stage 9) with its full,
   pushable ECR path and version tag, then pushes it.
3. Repeats the same tag-and-push with `:latest` instead of the
   versioned tag — so the registry always has one "most recent" tag
   available, in addition to every historical version.

**`withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-creds']])`:**
**[LINK]** this is a different mechanism from `credentials('aws-account-id')`
used earlier in the `environment` block. Instead of injecting one
plain string, `AmazonWebServicesCredentialsBinding` takes a stored
**AWS Credentials**-kind Jenkins Credential (ID `aws-creds`, created in
Phase 10, Step 34, holding the IAM access key pair from Phase 6,
Step 16) and automatically sets the standard
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` environment variables for
every command *inside this block only* — the AWS CLI then picks these
up completely automatically, with no extra flags needed in the `sh`
script itself.

**Why this uses `'''` (triple single-quote) instead of a plain `sh
"..."` like Stage 9:** this is a multi-line script, and critically, it
needs the **shell**, not Groovy, to expand `${AWS_REGION}`,
`${ECR_REGISTRY}`, etc. — see [Section 8](#8-the-groovy-string-quoting-trap--read-this-once)
for the full explanation of why this distinction is deliberate and
necessary here.

**Credential used:** `aws-creds` (AWS Credentials kind).

**Plugin required:** **AWS Credentials** plugin (provides the
`AmazonWebServicesCredentialsBinding` class) and **AWS Steps** plugin.

**If this fails with an access-denied error:** verify the `aws-creds`
IAM user still has `AmazonEC2ContainerRegistryFullAccess` attached, and
that the symlink making `aws` visible to the `jenkins` system user
(main guide Phase 7, Step 21) is still in place.

---

### Stage 12 — `Update Manifests Repo`

```groovy
stage('Update Manifests Repo') {
    steps {
        script {
            cleanWs()
            withCredentials([usernamePassword(
                    credentialsId: 'git',
                    usernameVariable: 'GIT_USER',
                    passwordVariable: 'GIT_PASS')]) {
                sh '''
                    git clone https://${GIT_USER}:${GIT_PASS}@github.com/nihitkumar78/medibot-manifests.git
                    cd medibot-manifests

                    sed -i "s|image:.*medibot:.*|image: ${IMAGE_FULL}:${IMAGE_TAG}|g" deployment.yaml

                    git config user.name "Jenkins"
                    git config user.email "jenkins@medibot.com"
                    git add deployment.yaml
                    git commit -m "Update image to ${IMAGE_TAG} [build #${BUILD_NUMBER}]"
                    git push origin main
                '''
            }
        }
    }
}
```

**This is the single most important stage in the entire file** — it's
the one and only moment this pipeline connects CI to CD. Everything
before this point only built and validated an image; this stage is
what actually tells the rest of the system "a new version exists."

**`script { }`:** declarative pipelines normally restrict you to a
fixed set of step types inside `steps { }` — wrapping a block in
`script { }` drops into full, unrestricted Groovy/Scripted Pipeline
syntax for anything inside it. It's used here specifically because
`cleanWs()` needs to run as a standalone statement before the
`withCredentials` block even starts, which isn't expressible in the
plain declarative style used by every other stage in this file.

**`cleanWs()`:** wipes the entire Jenkins workspace directory clean
before continuing. **Why here specifically:** the workspace currently
contains the `medibot-app` checkout from Stage 1, plus build artifacts
from every stage since — none of that is relevant to this stage, which
needs to clone a completely different repo (`medibot-manifests`) into
a clean directory. Skipping this wouldn't necessarily break anything
immediately, but risks stale files from a previous run interfering
with a future one.

**`withCredentials([usernamePassword(credentialsId: 'git', ...)])`:**
reuses the **same** `git` credential from Stage 1 — but note the
*mechanism* is different: Stage 1 passed `credentialsId: 'git'`
directly to the built-in `git` step, which handles authentication
internally and never exposes the raw token. Here, `usernamePassword(...)`
extracts the credential's username/password into two **named shell
variables** (`GIT_USER`/`GIT_PASS`), because the following `sh` script
needs to build a raw authenticated clone URL by hand
(`https://${GIT_USER}:${GIT_PASS}@github.com/...`) — a pattern Git
supports natively for HTTPS-based authentication.

**`sed -i "s|image:.*medibot:.*|image: ${IMAGE_FULL}:${IMAGE_TAG}|g" deployment.yaml`:**
**[LINK]** the actual CI→CD handoff. `sed` is a text-stream editor;
this specific command finds any line in `deployment.yaml` matching the
pattern `image:` followed by anything, then `medibot:` followed by
anything (i.e., the app container's `image:` line — see the
[Manifests Explained doc](./MediBot-Manifests-Explained.md), Section
5.2), and replaces the *entire matched line* with the new, real image
reference this exact build just pushed to ECR in Stage 11. This line
is a **double-quoted** string (unlike the surrounding `sh '''...'''`
block it sits inside), so `${IMAGE_FULL}` and `${IMAGE_TAG}` here are
interpolated by **Groovy**, not the shell — see
[Section 8](#8-the-groovy-string-quoting-trap--read-this-once) for why
this one line breaks the pattern of everything around it, deliberately.

**`git add` / `commit` / `push`:** commits that one-line change and
pushes it straight to `medibot-manifests`' `main` branch, authenticated
as a synthetic "Jenkins" git identity (`git config user.name`/
`user.email` — these aren't a real GitHub account, just metadata
attached to the commit, visible in the repo's history).

**What happens next, outside this Jenkinsfile entirely:** ArgoCD,
which is continuously polling this exact repo (main setup guide Phase
13), notices the new commit and automatically syncs the updated
`deployment.yaml` into the cluster — Jenkins' job is done the moment
this `git push` succeeds; it never touches Kubernetes directly.

**Credential used:** `git` (same credential as Stage 1, different
consumption mechanism).

**Plugin required:** none beyond core Jenkins pipeline support —
`cleanWs()` comes from the **Workspace Cleanup** plugin (commonly
bundled/installed by default in most Jenkins setups), and
`usernamePassword()` comes from core **Credentials Binding** plugin
functionality.

**If this fails:** check the `git` credential's token hasn't expired
(GitHub PATs created with an expiration, per the main setup guide's
Phase 1, Step 2, stop working after 90 days) and that
`medibot-manifests`' branch protection (if any) doesn't block direct
pushes to `main`.

---

## 6. Master Credentials Table

| Credential ID | Kind | Created in (main setup guide) | Holds | Used in this Jenkinsfile |
|---|---|---|---|---|
| `git` | Username with password | Phase 10, Step 34 | GitHub username + Personal Access Token (from Phase 1, Step 2) | Stage 1 (`Git Checkout`, via `credentialsId:`); Stage 12 (`Update Manifests Repo`, via `usernamePassword()`) |
| `sonar-token` | Secret text | Phase 10, Step 34 | SonarQube analysis token (from Phase 8, Step 26) | Stage 6 (`Quality Gate`, via `credentialsId:`) |
| `aws-creds` | AWS Credentials | Phase 10, Step 34 | IAM access key pair for `medibot-jenkins-ecr` (from Phase 6, Step 16) | Stage 11 (`Push to ECR`, via `AmazonWebServicesCredentialsBinding`) |
| `aws-account-id` | Secret text | Phase 10, Step 34 | Your plain AWS account ID, `719152986284` | `environment {}` block (via `credentials()`), feeding `ECR_REGISTRY`/`IMAGE_FULL` used in Stages 9, 10, 11, 12 |
| `medibot-nexus` (a Managed File, not a Credential object) | Global Maven Settings XML | Phase 10, Step 36 | Nexus `jenkins` user's password (from Phase 9, Step 29), embedded in a `settings.xml` | Stage 8 (`Publish to Nexus`, via `withMaven(globalMavenSettingsConfig:)`) |
| SonarQube server's own token | (configured server-wide, not per-credential here) | Phase 10, Step 35 | Same `sonar-token` value, referenced by server name | Stage 5 (`SonarQube Analysis`, via `withSonarQubeEnv('sonar')`) |

---

## 7. Master Plugin Table

| Plugin | What it enables in this Jenkinsfile | What breaks without it |
|---|---|---|
| **Maven Integration** | The `tools { maven 'maven3' }` block, and the named Maven installation it refers to | `mvn` would not be on `PATH` — every `sh 'mvn ...'` call fails with "command not found" |
| **SonarQube Scanner** | `tool 'sonar-scanner'`, `withSonarQubeEnv('sonar')`, `waitForQualityGate` | Stages 5 and 6 fail outright — these functions don't exist without the plugin |
| **Pipeline Maven Integration** | The `withMaven(...)` step used in Stage 8 | Stage 8 fails — `withMaven` is undefined |
| **Config File Provider** | Managed Files like `medibot-nexus`, referenced via `globalMavenSettingsConfig:` | Stage 8 fails — there's no `settings.xml` to inject, so `mvn deploy` has no Nexus credentials and fails with a 401 |
| **AWS Credentials** | The `AmazonWebServicesCredentialsBinding` class used in Stage 11 | Stage 11 fails — `withCredentials` has no binding type for AWS keys |
| **AWS Steps** | General AWS-specific pipeline step support (installed alongside AWS Credentials in this project) | Not directly called by name in this file, but installed as part of the same AWS tooling setup |
| **Docker** / **Docker Pipeline** | Richer Docker-specific pipeline syntax elsewhere in Jenkins' ecosystem | This specific file's plain `sh "docker build..."` calls would actually still work without these, since they're just shell commands — these plugins matter more if you later adopt the `docker.build()`/`docker.withRegistry()` style syntax instead |
| **Pipeline Stage View** | Nothing this file depends on functionally — purely a visual pipeline graph in the Jenkins UI | Cosmetic only; the pipeline runs identically either way |
| Core Git support (bundled by default) | The `git branch:`, `credentialsId:`, `url:` step in Stage 1 | Stage 1 fails — no way to check out source at all |
| Core Credentials Binding (bundled by default) | `credentials()` in the `environment` block, `usernamePassword()` in Stage 12 | Both fail without this foundational plugin, which almost every Jenkins install has by default |

---

## 8. The Groovy String Quoting Trap — Read This Once

This Jenkinsfile deliberately mixes **three different string styles**,
and which one is used in each spot is not arbitrary — it controls
*who* expands a `${...}` reference: **Groovy** (the pipeline script
engine itself) or **the shell** (bash, running on the Jenkins EC2).
Getting this backwards is one of the most common, hardest-to-diagnose
mistakes when writing or editing a Jenkinsfile.

| Style | Example from this file | Who expands `${...}` | When |
|---|---|---|---|
| Single-quoted Groovy string `'...'` | `sh 'mvn compile'` | Nobody — there's nothing to expand, it's a plain literal string passed as-is to the shell | Stages 2, 3, 4, 7 |
| Double-quoted Groovy string `"..."` | `sh "docker build -t ${ECR_REPO}:${IMAGE_TAG} ."` | **Groovy**, immediately, before the shell ever sees the command | Stage 9, 10, and the `sed` line inside Stage 12 |
| Triple single-quoted Groovy string `'''...'''` | `sh '''\n$SCANNER_HOME/bin/sonar-scanner ...\n'''` | **The shell**, when it runs — Groovy passes the text through completely untouched | Stages 5, 11, and the outer wrapper of Stage 12 |

**Why it matters, concretely:** inside Stage 11's `'''`-wrapped block,
you'll see `${AWS_REGION}` and `${ECR_REGISTRY}`. Because this is a
triple-*single*-quoted string, **Groovy does not touch these at all**
— they're passed to bash completely literally, as the text
`${AWS_REGION}`. Bash then sees that text, recognizes it as a shell
variable reference, and expands it **itself** — successfully, because
`AWS_REGION` and `ECR_REGISTRY` were already `export`-ed into the
process environment by the `environment {}` block (Section 4), and
every child process (including this `sh` script) inherits environment
variables automatically. The end result looks identical either way in
this case (same values get substituted), but the *mechanism* is
completely different depending on the quoting — and it would matter a
great deal if, say, a value contained a `$` or backtick character
Groovy would try to interpret differently than bash would.

**The practical rule of thumb used consistently in this file:** for a
short, single-line command, a double-quoted `"..."` Groovy string is
fine and common. For a longer, **multi-line** shell script (anything
with multiple commands, pipes, or control flow), a triple-quoted
`'''...'''` block is used instead — multi-line double-quoted Groovy
strings are awkward and error-prone, and letting the shell itself
handle variable expansion for a whole script block is simpler to
reason about once you know which variables are actually `export`-ed
into the environment (everything in this project's `environment {}`
block is).

---

## 9. What Triggers This Pipeline, End to End

```
Developer runs `git push` on medibot-app's main branch
        ↓
GitHub sends an HTTP POST to http://<jenkins-ip>:8080/github-webhook/
  (configured in the main setup guide's Phase 14, Step 47)
        ↓
Jenkins' "medibot-ci" job has "GitHub hook trigger for GITScm polling"
  enabled (configured in Phase 14, Step 46) — this tells it to react
  to that incoming webhook by polling the repo for changes right away
        ↓
Jenkins detects new commits on main, starts a new build
        ↓
Jenkins checks out the repo (implicit checkout from the job's SCM
  config, then the explicit `git` step in Stage 1)
        ↓
Jenkins parses and runs this Jenkinsfile's `pipeline { }` block,
  stage by stage, top to bottom, stopping immediately on the first
  stage that fails (except where a stage is explicitly configured
  to tolerate failure, like Quality Gate's abortPipeline: false)
```

A build can also be started manually at any time via **Jenkins UI →
`medibot-ci` → Build Now** — this runs the exact same pipeline, just
without a webhook having triggered it; useful for re-running after
fixing a configuration issue without needing a new commit.

---

## 10. General Beginner FAQ

**Q: What shell does `sh '...'` actually run?**
A: Whatever `/bin/sh` points to on the Jenkins EC2 — on this Ubuntu
instance, that's typically `dash`, a lighter, more POSIX-strict shell
than `bash`. Most simple commands behave identically either way, but
some `bash`-specific syntax (certain advanced parameter expansions,
`[[ ]]` test syntax) would not work inside a plain `sh` step.

**Q: What's the difference between `withCredentials` and the plain
`credentials()` function?**
A: `credentials('id')` (used in the `environment {}` block) is the
simpler form — it injects one credential's value directly as an
environment variable, available everywhere in the pipeline from that
point on. `withCredentials([...])` (used in Stages 6, 11, 12) is more
flexible — it can bind *multiple* parts of a credential at once (like
splitting a username/password pair into two separate variables, as
Stage 12 does), and critically, the variables it creates **only exist
inside that specific block** — once the block ends, they're gone,
which is a slightly tighter security boundary than the `environment{}`
approach.

**Q: Does a failed stage automatically retry?**
A: No. A failed stage stops the entire pipeline immediately (unless
explicitly wrapped in `catchError` or similar, which this file doesn't
use anywhere). You have to manually trigger a new build — either by
pushing a new commit, or clicking **Build Now** again.

**Q: How does Jenkins know Stage 2 succeeded before starting Stage 3?**
A: Every `sh` step's exit code is checked automatically — a non-zero
exit code (the standard Unix convention for "something failed") marks
that step, and therefore that stage, as failed, which stops the
pipeline. You never have to check exit codes yourself in a Jenkinsfile
— the pipeline engine does it for every step implicitly.

**Q: Where do I actually view the console output of a run?**
A: **Jenkins UI → `medibot-ci` → [build number] → Console Output** —
this shows the complete, real-time (or historical) log of every
command this pipeline ran, including the exact `sh` commands after
Groovy's variable interpolation has already happened (so you'll see
real values, not `${...}` placeholders, for anything Groovy-interpolated).

**Q: What's `BUILD_NUMBER` vs. `BUILD_ID` vs. `BUILD_TAG`?**
A: All three are built-in Jenkins variables, automatically available
in every pipeline without you declaring them. `BUILD_NUMBER` is the
plain incrementing integer used in this file (`v1`, `v2`, ...).
`BUILD_ID` is historically the same value as `BUILD_NUMBER` in modern
Jenkins (it used to be a timestamp in very old versions). `BUILD_TAG`
is a longer, pre-formatted string combining the job name and build
number (e.g. `jenkins-medibot-ci-8`), handy as a unique identifier when
you need one string instead of composing your own.

**Q: Could I add a stage that deploys straight to Kubernetes with
`kubectl apply`, instead of going through ArgoCD?**
A: Technically yes (Jenkins' kubeconfig was even copied onto this box
back in the main guide's Phase 7, Step 23, partly for ad-hoc debugging
access) — but doing so would break the GitOps model this entire
project is built around: Git would no longer be a reliable record of
what's actually deployed, since changes could land in the cluster
without ever being committed anywhere. The whole reason this Jenkinsfile
stops at "push an updated manifest to Git" (Stage 12) instead of
"deploy directly" is to preserve that guarantee.
