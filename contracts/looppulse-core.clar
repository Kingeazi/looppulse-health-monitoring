;; looppulse-core
;; 
;; This contract serves as the central hub for the LoopPulse Health Monitoring platform, 
;; handling user registration, health data recording, and access control. It maintains a secure 
;; registry of health records while implementing sophisticated permission systems that allow 
;; temporary access grants to authorized healthcare providers.

;; Error Codes
(define-constant ERR-NOT-AUTHORIZED (err u1001))
(define-constant ERR-USER-NOT-FOUND (err u1002))
(define-constant ERR-PROVIDER-NOT-REGISTERED (err u1003))
(define-constant ERR-ACCESS-DENIED (err u1004))
(define-constant ERR-ACCESS-EXPIRED (err u1005))
(define-constant ERR-INVALID-METRIC-TYPE (err u1006))
(define-constant ERR-INVALID-DATA (err u1007))
(define-constant ERR-ALREADY-REGISTERED (err u1008))
(define-constant ERR-INVALID-EXPIRY (err u1009))

;; Data space definitions

;; Valid health metric types
(define-constant METRIC-HEART-RATE u1)
(define-constant METRIC-BLOOD-PRESSURE u2)
(define-constant METRIC-GLUCOSE u3)
(define-constant METRIC-TEMPERATURE u4)
(define-constant METRIC-OXYGEN u5)
(define-constant METRIC-WEIGHT u6)
(define-constant METRIC-STEPS u7)
(define-constant METRIC-SLEEP u8)

;; User registry - tracks registered users
(define-map users 
  { user-id: principal }
  { registered: bool, registration-time: uint }
)

;; Healthcare provider registry
(define-map healthcare-providers
  { provider-id: principal }
  { name: (string-ascii 64), registered: bool, registration-time: uint }
)

;; Health metrics data store - maps user to their health data entries
(define-map health-metrics
  { user-id: principal, metric-id: uint }
  { 
    metric-type: uint,
    value: (list 10 int),  ;; Some metrics like blood pressure need multiple values
    timestamp: uint,
    metadata: (optional (string-utf8 256))
  }
)

;; Access permissions - tracks who has access to which user's data
(define-map access-permissions
  { user-id: principal, provider-id: principal }
  {
    granted-at: uint,
    expires-at: uint,
    metric-types: (list 8 uint)  ;; List of allowed metric types
  }
)

;; Access logs - records all data access events for audit
(define-map access-logs
  { log-id: uint }
  {
    user-id: principal,
    accessor-id: principal,
    metric-type: uint,
    accessed-at: uint
  }
)

;; Track the next metric ID for each user
(define-map user-metrics-counter
  { user-id: principal }
  { next-id: uint }
)

;; Track next log ID for access logs
(define-data-var next-log-id uint u1)

;; Private functions

;; Check if a user is registered
(define-private (is-user-registered (user-id principal))
  (default-to false (get registered (map-get? users { user-id: user-id })))
)

;; Check if a provider is registered
(define-private (is-provider-registered (provider-id principal))
  (default-to false (get registered (map-get? healthcare-providers { provider-id: provider-id })))
)

;; Check if a metric type is valid
(define-private (is-valid-metric-type (metric-type uint))
  (or
    (is-eq metric-type METRIC-HEART-RATE)
    (is-eq metric-type METRIC-BLOOD-PRESSURE)
    (is-eq metric-type METRIC-GLUCOSE)
    (is-eq metric-type METRIC-TEMPERATURE)
    (is-eq metric-type METRIC-OXYGEN)
    (is-eq metric-type METRIC-WEIGHT)
    (is-eq metric-type METRIC-STEPS)
    (is-eq metric-type METRIC-SLEEP)
  )
)

;; Check if a provider has access to a user's data
(define-private (has-access (user-id principal) (provider-id principal) (metric-type uint))
  (let ((permission (map-get? access-permissions { user-id: user-id, provider-id: provider-id })))
    (if (is-none permission)
      false
      (let ((permission-data (unwrap-panic permission)))
        (and
          ;; Check if access hasn't expired
          (< (get-block-height) (get expires-at permission-data))
          ;; Check if the provider has access to this metric type
          (is-some (index-of (get metric-types permission-data) metric-type))
        )
      )
    )
  )
)

;; Get next metric ID for a user
(define-private (get-next-metric-id (user-id principal))
  (let ((counter (default-to { next-id: u1 } (map-get? user-metrics-counter { user-id: user-id }))))
    (begin
      (map-set user-metrics-counter 
        { user-id: user-id } 
        { next-id: (+ (get next-id counter) u1) }
      )
      (get next-id counter)
    )
  )
)

;; Log an access event
(define-private (log-access (user-id principal) (accessor-id principal) (metric-type uint))
  (let ((log-id (var-get next-log-id)))
    (begin
      (map-set access-logs
        { log-id: log-id }
        {
          user-id: user-id,
          accessor-id: accessor-id,
          metric-type: metric-type,
          accessed-at: (get-block-height)
        }
      )
      (var-set next-log-id (+ log-id u1))
      true
    )
  )
)

;; Public functions

;; Register a new user
(define-public (register-user)
  (let ((sender tx-sender))
    (if (is-user-registered sender)
      ERR-ALREADY-REGISTERED
      (begin
        (map-set users 
          { user-id: sender } 
          { registered: true, registration-time: (get-block-height) }
        )
        (map-set user-metrics-counter
          { user-id: sender }
          { next-id: u1 }
        )
        (ok true)
      )
    )
  )
)

;; Register a new healthcare provider
(define-public (register-healthcare-provider (name (string-ascii 64)))
  (let ((sender tx-sender))
    (if (is-provider-registered sender)
      ERR-ALREADY-REGISTERED
      (begin
        (map-set healthcare-providers
          { provider-id: sender }
          { name: name, registered: true, registration-time: (get-block-height) }
        )
        (ok true)
      )
    )
  )
)

;; Record a health metric
(define-public (record-health-metric (metric-type uint) (values (list 10 int)) (metadata (optional (string-utf8 256))))
  (let ((sender tx-sender))
    (if (not (is-user-registered sender))
      ERR-USER-NOT-FOUND
      (if (not (is-valid-metric-type metric-type))
        ERR-INVALID-METRIC-TYPE
        (let ((metric-id (get-next-metric-id sender)))
          (begin
            (map-set health-metrics
              { user-id: sender, metric-id: metric-id }
              {
                metric-type: metric-type,
                value: values,
                timestamp: (get-block-height),
                metadata: metadata
              }
            )
            (ok metric-id)
          )
        )
      )
    )
  )
)

;; Grant access to a healthcare provider
(define-public (grant-access (provider-id principal) (duration uint) (metric-types (list 8 uint)))
  (let ((sender tx-sender))
    (if (not (is-user-registered sender))
      ERR-USER-NOT-FOUND
      (if (not (is-provider-registered provider-id))
        ERR-PROVIDER-NOT-REGISTERED
        (if (> duration u8640) ;; Limit access to max ~30 days (assuming 144 blocks per day)
          ERR-INVALID-EXPIRY
          (begin
            (map-set access-permissions
              { user-id: sender, provider-id: provider-id }
              {
                granted-at: (get-block-height),
                expires-at: (+ (get-block-height) duration),
                metric-types: metric-types
              }
            )
            (ok true)
          )
        )
      )
    )
  )
)

;; Revoke access from a healthcare provider
(define-public (revoke-access (provider-id principal))
  (let ((sender tx-sender))
    (if (not (is-user-registered sender))
      ERR-USER-NOT-FOUND
      (if (is-none (map-get? access-permissions { user-id: sender, provider-id: provider-id }))
        (ok true) ;; No access to revoke, return success
        (begin
          (map-delete access-permissions { user-id: sender, provider-id: provider-id })
          (ok true)
        )
      )
    )
  )
)

;; Read-only functions

;; Check if a user is registered
(define-read-only (check-user-registration (user-id principal))
  (is-user-registered user-id)
)

;; Check if a provider is registered
(define-read-only (check-provider-registration (provider-id principal))
  (is-provider-registered provider-id)
)

;; Get health metric data
(define-read-only (get-health-metric (user-id principal) (metric-id uint))
  (let ((sender tx-sender)
        (metric-data (map-get? health-metrics { user-id: user-id, metric-id: metric-id })))
    (if (is-none metric-data)
      (err u0) ;; Metric not found
      (let ((data (unwrap-panic metric-data)))
        ;; Check access authorization
        (if (or 
              (is-eq sender user-id) ;; User accessing their own data
              (has-access user-id sender (get metric-type data)) ;; Provider with valid access
            )
          (begin
            ;; Log access if it's not the user themselves
            (if (not (is-eq sender user-id))
              (log-access user-id sender (get metric-type data))
              true
            )
            ;; Return the health metric data
            (ok data)
          )
          ERR-ACCESS-DENIED
        )
      )
    )
  )
)

;; Get user metrics by type
(define-read-only (get-metrics-by-type (user-id principal) (metric-type uint) (limit uint))
  (let ((sender tx-sender))
    (if (not (is-valid-metric-type metric-type))
      ERR-INVALID-METRIC-TYPE
      ;; Check access authorization
      (if (or 
            (is-eq sender user-id) ;; User accessing their own data
            (has-access user-id sender metric-type) ;; Provider with valid access
          )
        (begin
          ;; Log access if it's not the user themselves
          (if (not (is-eq sender user-id))
            (log-access user-id sender metric-type)
            true
          )
          ;; Return success - in a real implementation, this would return actual data
          ;; but for simplicity we just return success
          (ok true)
        )
        ERR-ACCESS-DENIED
      )
    )
  )
)

;; Check access status for a provider
(define-read-only (check-access-status (user-id principal) (provider-id principal))
  (let ((permission (map-get? access-permissions { user-id: user-id, provider-id: provider-id })))
    (if (is-none permission)
      (ok { has-access: false, expires-at: u0, metric-types: (list) })
      (let ((permission-data (unwrap-panic permission))
            (current-height (get-block-height)))
        (ok {
          has-access: (< current-height (get expires-at permission-data)),
          expires-at: (get expires-at permission-data),
          metric-types: (get metric-types permission-data)
        })
      )
    )
  )
)

;; Get a user's access log by ID
(define-read-only (get-access-log (log-id uint))
  (let ((sender tx-sender)
        (log-data (map-get? access-logs { log-id: log-id })))
    (if (is-none log-data)
      (err u0) ;; Log not found
      (let ((data (unwrap-panic log-data)))
        ;; Only the user whose data was accessed can see the log
        (if (is-eq sender (get user-id data))
          (ok data)
          ERR-NOT-AUTHORIZED
        )
      )
    )
  )
)