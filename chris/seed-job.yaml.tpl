# chris/seed-job.yaml.tpl — chrisomatic as a Kubernetes Job, rendered and
# applied by chris-seed.sh. The config (which embeds credentials) is mounted
# from Secret ${CHRIS_RELEASE}-seed-config, created in the same step.
apiVersion: batch/v1
kind: Job
metadata:
  name: ${CHRIS_RELEASE}-seed
  namespace: ${CHRIS_NAMESPACE}
  labels:
    app.kubernetes.io/name: chrisomatic
    app.kubernetes.io/instance: ${CHRIS_RELEASE}
    app.kubernetes.io/part-of: chris
spec:
  # chrisomatic is idempotent and cheap: fail fast, diagnose, re-run
  # 'just chris-seed' instead of retrying blind.
  backoffLimit: 0
  activeDeadlineSeconds: ${SEED_TIMEOUT}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: chrisomatic
        app.kubernetes.io/instance: ${CHRIS_RELEASE}
    spec:
      restartPolicy: Never
      containers:
        - name: chrisomatic
          image: ${CHRISOMATIC_IMAGE}
          command: ["chrisomatic", "/etc/chrisomatic/chrisomatic.yml"]
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 512Mi
          volumeMounts:
            - name: config
              mountPath: /etc/chrisomatic
              readOnly: true
      volumes:
        - name: config
          secret:
            secretName: ${CHRIS_RELEASE}-seed-config
