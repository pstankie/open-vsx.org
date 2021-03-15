local utils = import "utils.libsonnet";

local labels(env) = {
  app: env.appName,
  environment: env.envName,
};

local namespacedResourceMetadata(env) = {
  name: "%s-%s" % [ env.appName, env.envName, ],
  namespace: env.namespace,
  labels: labels(env),
};

local newEnvironment(envName) = {
  envName: envName,
  appName: "open-vsx-org",
  namespace: self.appName,
  host: if envName == "staging" then "staging.open-vsx.org" else "open-vsx.org",

  elasticsearch: {
    local thisES = self,
    name: "elasticsearch-%s" % envName,
    httpCerts: {
      # This secret is generated by the ELK operator. We control the naming scheme
      # via the name of the ES instance. 
      secretName: "%s-es-http-certs-internal" % thisES.name,
      caFilename: "ca.crt"
    },
    truststore: {
      path: "/run/secrets/open-vsx.org/truststore",
      filename: "elasticsearch-http-certs.keystore",
      password: "changeit", # we don't care making this one public!
    }
  },

  googleCloudStorage: {
    secretName: "google-cloud-storage-%s" % envName,
    credentialsFilename: "service_account.json",
  },

  deploymentConfig: {
    secretName: "deployment-configuration-%s" % envName,
    path: "/run/secrets/open-vsx.org/deployment",
    filename: "configuration.yml",
  },
};

local newDeployment(env, dockerImage) = {
  
  local elasticsearchCertsVolumeName = "elastic-internal-http-certificates",
  local googleCloudStorageCredsVolumeName = "google-cloud-storage-credentials",
  local truststoreWithESCertsVolumeName = "truststore-with-elasticsearch-certs",
  local deploymentConfigurationVolumeName = "deployment-configuration",

  apiVersion: "apps/v1",
  kind: "Deployment",
  metadata: namespacedResourceMetadata(env),
  spec: {
    replicas: 1,
    selector: {
      matchLabels: labels(env),
    },
    template: {
      metadata: {
        labels: labels(env),
      },
      spec: {
        local thisPod = self,
        initContainers: [
          {
            local thisContainer = self,
            name: "init-keystore",
            image: dockerImage,
            command: [
              "sh",
              "-c",
              "keytool -import -noprompt -alias es-http-certs-internal -file %s/%s -storetype jks -storepass '%s' -keystore %s/%s" % [ 
                thisContainer._volumeMounts[elasticsearchCertsVolumeName], 
                env.elasticsearch.httpCerts.caFilename,
                env.elasticsearch.truststore.password,
                thisContainer._volumeMounts[truststoreWithESCertsVolumeName], 
                env.elasticsearch.truststore.filename
              ],
            ],
            volumeMounts: utils.pairList(self._volumeMounts, vfield="mountPath"),
            _volumeMounts:: {
              [elasticsearchCertsVolumeName]: "/run/secrets/elasticsearch/http-certs",
              [truststoreWithESCertsVolumeName]: env.elasticsearch.truststore.path,
            },
          }
        ],
        containers: utils.namedObjectList(self._containers),
        _containers:: {
          [env.appName]: {
            local thisContainer = self,
            name: env.appName,
            image: dockerImage,
            env: utils.pairList(self._env),
            local jvmPerfOptions = " -XX:+AlwaysPreTouch -XX:+HeapDumpOnOutOfMemoryError -XX:+UseStringDeduplication -XX:+ParallelRefProcEnabled -XX:+DisableExplicitGC -XX:+UnlockExperimentalVMOptions -XX:+UnlockDiagnosticVMOptions",
            _env:: {
              JVM_ARGS: (if (env.envName == "staging") then "-Xms512M -Xmx1536M" else "-Xms1536M -Xmx6G") + jvmPerfOptions,
              GOOGLE_APPLICATION_CREDENTIALS: "%s/%s" % [
                thisContainer._volumeMounts[googleCloudStorageCredsVolumeName],
                env.googleCloudStorage.credentialsFilename,
              ],
              DEPLOYMENT_CONFIG: "%s/%s" % [ env.deploymentConfig.path, env.deploymentConfig.filename, ],
            },
            ports: utils.pairList(self._ports, vfield="containerPort"),
            _ports:: {
              http: 8080,
              "http-management": 8081,
            },
            volumeMounts: utils.pairList(self._volumeMounts, vfield="mountPath"),
            _volumeMounts:: {
              [deploymentConfigurationVolumeName]: env.deploymentConfig.path,
              [googleCloudStorageCredsVolumeName]: "/run/secrets/google-cloud-storage",
              [truststoreWithESCertsVolumeName]: env.elasticsearch.truststore.path,
            },
            resources: if (env.envName == "staging") then {
              requests: {
                memory: "2Gi",
                cpu: "250m",
              },
              limits: {
                memory: "2Gi",
                cpu: "1000m",
              }
            } else {
              requests: {
                memory: "8Gi",
                cpu: "4000m",
              },
              limits: {
                memory: "8Gi",
                cpu: "8000m",
              }
            },
            livenessProbe: {
              httpGet: {
                path: "/actuator/health/liveness",
                port: "http-management"
              },
              failureThreshold: 3,
              periodSeconds: 10
            },
            readinessProbe: {
              httpGet: {
                path: "/actuator/health/readiness",
                port: "http-management"
              },
              failureThreshold: 2,
              periodSeconds: 10
            },
            startupProbe: {
              httpGet: {
                path: "/actuator/health/readiness",
                port: "http-management"
              },
              failureThreshold: 30,
              periodSeconds: 10
            }
          },
        },
        volumes: utils.namedObjectList(self._volumes),
        _volumes:: {
          [deploymentConfigurationVolumeName]: {
            local thisVolume = self,
            secret: {
              defaultMode: 420,
              optional: false,
              secretName: env.deploymentConfig.secretName,
            }
          },
          [googleCloudStorageCredsVolumeName]: {
            local thisVolume = self,
            secret: {
              defaultMode: 420,
              optional: false,
              secretName: env.googleCloudStorage.secretName,
            }
          },
          [truststoreWithESCertsVolumeName]: {
            emptyDir: {
              medium: "Memory"
            }
          },
          [elasticsearchCertsVolumeName]: {
            secret: {
              defaultMode: 420,
              optional: false,
              secretName: env.elasticsearch.httpCerts.secretName,
            }
          },
        },
      }
    }
  }
};

local newService(env, deployment) = {
  apiVersion: "v1",
  kind: "Service",
  metadata: namespacedResourceMetadata(env),
  spec: {
    selector: labels(env),
    ports: utils.namedObjectList(self._ports),
    _ports:: {
      http: {
        port: 80,
        protocol: "TCP",
        targetPort: deployment.spec.template.spec._containers[env.appName]._ports["http"],
      },
    },
  },
};

local newRoute(env, service) = {
  apiVersion: "route.openshift.io/v1",
  kind: "Route",
  metadata: namespacedResourceMetadata(env) {
    annotations: {
      "haproxy.router.openshift.io/timeout": if (env.envName == "staging") then "30s" else "10m",
      "haproxy.router.openshift.io/disable_cookies": "true",
    },
  },
  spec: {
    host: env.host,
    path: "/",
    port: {
      targetPort: service.spec._ports["http"].targetPort,
    },
    tls: {
      insecureEdgeTerminationPolicy: "Redirect",
      termination: "edge"
    },
    to: {
      kind: "Service",
      name: service.metadata.name,
      weight: 100
    }
  }
};

local newElasticSearchCluster(env) = {
  apiVersion: "elasticsearch.k8s.elastic.co/v1",
  kind: "Elasticsearch",
  metadata: {
    name: env.elasticsearch.name,
    namespace: env.namespace,
    labels: labels(env),
  },
  spec: {
    version: "7.9.3",
    nodeSets: [
      {
        name: "default",
        config: {
          "node.roles": [ "master", "data" ],
          "node.store.allow_mmap": false
        },
        podTemplate: {
          metadata: {
            labels: labels(env),
          },
          spec: {
            containers: [
              {
                name: "elasticsearch",
                env: utils.pairList(self._env),
                _env:: {
                  ES_JAVA_OPTS: if (env.envName == "staging") then "-Xms1g -Xmx1g" else "-Xms4g -Xmx4g",
                },
                resources: {
                  requests: {
                    memory: if (env.envName == "staging") then "2Gi" else "8Gi",
                    cpu: 1
                  },
                  limits: {
                    memory: if (env.envName == "staging") then "2Gi" else "8Gi",
                    cpu: if (env.envName == "staging") then 1 else 4,
                  }
                }
              }
            ]
          }
        },
        count: if (env.envName == "staging") then 1 else 3,
      }
    ],
  }
};

local _newKubernetesResources(envName, image) = {
  local environment = newEnvironment(envName),
  local deployment = newDeployment(environment, image),
  local service = newService(environment, deployment),

  arr: [
    deployment,
    service,
    newRoute(environment, service),
    newElasticSearchCluster(environment),
  ] + if envName == "production" then [ newRoute(environment, service) {
      metadata+: {
        name: "www-%s" % environment.appName
      },
      spec+: {
        host: "www.%s" % environment.host 
      },
  }] else [],
};

local newKubernetesResources(envName, image) = _newKubernetesResources(envName, image).arr;

local newKubernetesYamlStream(envName, image) = 
  std.manifestYamlStream(newKubernetesResources(envName, image), false, false);

{
  newEnvironment:: newEnvironment,
  newDeployment:: newDeployment,
  newService:: newService,
  newRoute:: newRoute,
  newElasticSearchCluster:: newElasticSearchCluster,
  
  newKubernetesResources:: newKubernetesResources,
  newKubernetesYamlStream:: newKubernetesYamlStream,
}
