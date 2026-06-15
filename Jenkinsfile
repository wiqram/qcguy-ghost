pipeline {
    agent none
    stages {
        // Refresh qcguy's Vault secret (kv/qcguy/ghost = the Ghost config) from this
        // repo's vault/ dir BEFORE deploy, under qcguy's scoped AppRole.
        stage('Refresh Vault secrets') {
            agent {
                kubernetes { cloud 'kubernetes'; label 'kubeagent'; defaultContainer 'jnlp' }
            }
            steps {
                checkout scm
                script {
                    library identifier: 'vault-tools@main', retriever: modernSCM([
                        $class: 'GitSCMSource',
                        remote: 'https://github.com/wiqram/vault.git',
                        credentialsId: '46f819a6-2a0e-4943-a5ae-49f1dac74f4e'
                    ])
                    vaultSync(app: 'qcguy')
                }
            }
        }
        stage('Deploy K8s qcguy') {
            agent {
                kubernetes { cloud 'kubernetes'; label 'kubeagent'; defaultContainer 'jnlp' }
            }
            steps {
                checkout scm
                sh 'kubectl apply -f compiled.yaml'
                sh 'kubectl rollout status deployment -n qcguy qcguy --timeout=240s'
            }
        }
    }
}
