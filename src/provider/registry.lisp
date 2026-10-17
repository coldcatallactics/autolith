(in-package #:autolith)

;;;; -- Provider Registry --

;;; Provider registrations, their source layers, model discovery and the model
;;; cache live in cl-llm-provider-api/registry. Autolith owns one registry, the
;;; extension source a load binds, the private cache file, the configuration
;;; condition protocol, and the legacy model tables kept in step with it.

(defparameter *provider-registration-sources*
  '(:builtin :plugin :site :user :runtime)
  "The provider registration sources ordered from lowest to highest precedence.")

(defvar *provider-registry*
  (provider-registry-create
   :sources                   *provider-registration-sources*
   :default-context-window    *default-context-window*
   :default-reasoning-efforts *supported-reasoning-efforts*
   :cache-read-function       (lambda (configuration)
                                (provider--read-model-cache configuration))
   :cache-write-function      (lambda (configuration form)
                                (provider--write-model-cache configuration form))
   :change-function           (lambda (registry)
                                (declare (ignore registry))
                                (provider--refresh-model-settings)))
  "Every provider registration layer of this image and its model metadata.")

(setf *provider-registry-error-class* 'provider-registry-configuration-error)

(defvar *provider-registration-provenance* (make-hash-table :test #'equal)
  "Provider registration layers mapped to the source that supplied them.

Each key is a provider name paired with a layer keyword. The provider registry
records keyword layers only, so this table keeps each layer's registration
source for source-scoped removal and rollback.")

(defparameter *provider-name-aliases*
  '(("codex" . "chatgpt")
    ("openai" . "chatgpt"))
  "Legacy provider names mapped to registered provider names.")


;;;; -- Registration --

(-> register-provider
    (string &key
            (:description (option string))
            (:family (option keyword))
            (:models (option list))
            (:factory function)
            (:authenticator (option function))
            (:protocol keyword)
            (:endpoint (option string))
            (:model-discovery (option function))
            (:model-discovery-endpoint (option string))
            (:model-discovery-endpoint-resolver (option function))
            (:source registration-source-designator))
    string)
(defun register-provider
    (name &key description family models factory authenticator
      (protocol ':custom) endpoint model-discovery model-discovery-endpoint
      model-discovery-endpoint-resolver
      (source (current-registration-source)))
  "Register a provider and its model metadata.

FACTORY receives CONFIGURATION and the keyword REASONING-SUMMARIES-P and must
return a MODEL-PROVIDER. MODEL-DISCOVERY, when supplied, receives CONFIGURATION
and returns model strings or metadata property lists. The optional endpoint
resolver returns the current model-discovery cache identity. AUTHENTICATOR, when
supplied, receives the provider and the keyword arguments STREAM and
OPEN-BROWSER-P. Site, user, and live runtime registrations replace only the
same source and shadow lower-precedence registrations with the same name."
  (let ((source (registration-source-coerce source)))
    (provider-registry-register
     *provider-registry* name
     :description                       description
     :family                            family
     :models                            models
     :factory                           factory
     :authenticator                     authenticator
     :protocol                          protocol
     :endpoint                          endpoint
     :model-discovery                   model-discovery
     :model-discovery-endpoint          model-discovery-endpoint
     :model-discovery-endpoint-resolver model-discovery-endpoint-resolver
     :source                            (registration-source-layer source))
    (provider--record-registration name source)
    name))

(-> unregister-provider (string &key (:source registration-source-designator)) boolean)
(defun unregister-provider (name &key (source (current-registration-source)))
  "Remove NAME from one provider registration SOURCE layer."
  (let ((source (registration-source-coerce source)))
    (prog1
        (provider-registry-unregister *provider-registry* name
                                      :source (registration-source-layer source))
      (provider--forget-registration name source))))

(-> provider--current-registration-source () registration-source-designator)
(defun provider--current-registration-source ()
  "Return the registration source appropriate to the current load context."
  (current-registration-source))

(-> provider--canonical-name (string) string)
(defun provider--canonical-name (name)
  "Return NAME normalized for provider registry lookup."
  (or (cdr (assoc (string-downcase name) *provider-name-aliases* :test #'string=))
      (string-downcase name)))


;;;; -- Discovery and Cache --

(-> provider-load-model-cache (configuration) null)
(defun provider-load-model-cache (configuration)
  "Load successful dynamic model metadata from CONFIGURATION's private cache."
  (provider-registry-load-model-cache *provider-registry* configuration))

(-> provider-refresh-models
    (configuration &key (:provider-name (option string)))
    list)
(defun provider-refresh-models (configuration &key provider-name)
  "Refresh dynamic provider model lists and return discovery failures.

When PROVIDER-NAME is supplied, refresh only that effective registration. Static
registrations are ignored. Failures retain the last successful model list."
  (mapcar (lambda (failure)
            (make-condition 'provider-model-discovery-error
                            :message       (cl-llm-provider-api:provider-api-error-message
                                            failure)
                            :provider-name (cl-llm-provider-api:provider-model-discovery-error-provider-name
                                            failure)
                            :cause         (cl-llm-provider-api:provider-model-discovery-error-cause
                                            failure)))
          (provider-registry-refresh-models *provider-registry* configuration
                                            :provider-name provider-name)))

(-> provider-bootstrap-configuration
    (configuration &key (:refresh-p boolean))
    configuration)
(defun provider-bootstrap-configuration (configuration &key refresh-p)
  "Load local provider metadata and validate CONFIGURATION.

When REFRESH-P is true, also perform the explicit synchronous discovery operation.
The default startup path never performs remote model discovery."
  (provider-load-model-cache configuration)
  (when refresh-p
    (provider-refresh-models configuration))
  (configuration-validate-deferred configuration))

(-> provider--read-model-cache (configuration) t)
(defun provider--read-model-cache (configuration)
  "Return the model cache form in CONFIGURATION's private cache file, or NIL."
  (let ((pathname (configuration-provider-model-cache-path configuration)))
    (and (probe-file pathname)
         (read-portable-form pathname))))

(-> provider--write-model-cache (configuration list) null)
(defun provider--write-model-cache (configuration form)
  "Atomically replace CONFIGURATION's private model cache file with FORM."
  (let ((pathname (configuration-provider-model-cache-path configuration)))
    (ensure-directories-exist pathname)
    (snapshot-write pathname form :mode #o600))
  nil)


;;;; -- Effective Registry Views --

(-> provider-registrations () list)
(defun provider-registrations ()
  "Return the effective provider registrations in stable display order."
  (provider-registry-registrations *provider-registry*))

(-> provider-registration-find (string) (option provider-registration))
(defun provider-registration-find (name)
  "Return the effective provider registration named NAME."
  (provider-registry-find *provider-registry* name))

(-> provider-registration-for-model (string) (option provider-registration))
(defun provider-registration-for-model (model)
  "Return the highest-precedence effective provider serving MODEL.

When more than one provider claims MODEL, the registration source precedence and
then newest registration order decide which provider is effective."
  (provider-registry-for-model *provider-registry* model))

(-> provider-model-for (string) (option provider-model))
(defun provider-model-for (model)
  "Return the effective model metadata for MODEL."
  (provider-registry-model *provider-registry* model))

(-> provider-model-identifiers () list)
(defun provider-model-identifiers ()
  "Return unique model identifiers exposed by effective providers."
  (provider-registry-model-identifiers *provider-registry*))

(-> provider-model-family (string) (option keyword))
(defun provider-model-family (model)
  "Return the registered family serving MODEL, or NIL when unknown."
  (let ((registration (provider-registration-for-model model)))
    (and registration (provider-registration-family registration))))

(-> provider-model-endpoint (string) (option string))
(defun provider-model-endpoint (model)
  "Return the registered endpoint serving MODEL, when metadata declares one."
  (let ((registration (provider-registration-for-model model)))
    (and registration (provider-registration-endpoint registration))))

(-> provider-model-context-window-for (string) (option integer))
(defun provider-model-context-window-for (model)
  "Return the registered context window for MODEL, when metadata declares one."
  (let ((metadata (provider-model-for model)))
    (and metadata (provider-model-context-window metadata))))

(-> provider-model-reasoning-efforts-for (string) (option list))
(defun provider-model-reasoning-efforts-for (model)
  "Return the reasoning efforts declared for MODEL, when available."
  (let ((metadata (provider-model-for model)))
    (and metadata (copy-list (provider-model-reasoning-efforts metadata)))))

(-> provider-model-provider-name (string) (option string))
(defun provider-model-provider-name (model)
  "Return the display name of the provider serving MODEL, when known."
  (let ((registration (provider-registration-for-model model)))
    (and registration (provider-registration-name registration))))


;;;; -- Registry State --

(-> provider--refresh-model-settings () null)
(defun provider--refresh-model-settings ()
  "Synchronize legacy model tables with the effective provider registry."
  (let ((models (provider-model-identifiers)))
    (setf *supported-models* models
          *model-context-windows*
          (loop for model in models
                for window = (provider-model-context-window-for model)
                when window collect (cons model window))))
  nil)

(-> provider--record-registration (string registration-source-designator) null)
(defun provider--record-registration (name source)
  "Record SOURCE as the supplier of NAME's provider registry layer."
  (setf (gethash (cons (provider--canonical-name name)
                       (registration-source-layer source))
                 *provider-registration-provenance*)
        source)
  nil)

(-> provider--forget-registration (string registration-source-designator) null)
(defun provider--forget-registration (name source)
  "Forget NAME's provider registry layer when SOURCE supplied it."
  (let* ((source (registration-source-coerce source))
         (key (cons (provider--canonical-name name)
                    (registration-source-layer source))))
    (when (eq (gethash key *provider-registration-provenance*) source)
      (remhash key *provider-registration-provenance*)))
  nil)

(-> provider--forget-registration-layer (keyword) null)
(defun provider--forget-registration-layer (layer)
  "Forget every provider registry layer attributed to LAYER."
  (let ((keys nil))
    (maphash (lambda (key source)
               (declare (ignore source))
               (when (eq (rest key) layer)
                 (push key keys)))
             *provider-registration-provenance*)
    (dolist (key keys)
      (remhash key *provider-registration-provenance*)))
  nil)

(-> provider--remove-registration-source (registration-source-designator) null)
(defun provider--remove-registration-source (source)
  "Remove all provider registrations supplied by SOURCE."
  (let* ((source (registration-source-coerce source))
         (layer (registration-source-layer source)))
    (if (registration-source-plugin-p source)
        (let ((names nil))
          (maphash (lambda (key recorded)
                     (when (and (eq layer (rest key)) (eq source recorded))
                       (push (first key) names)))
                   *provider-registration-provenance*)
          (dolist (name names)
            (provider-registry-unregister *provider-registry* name :source layer)
            (remhash (cons name layer) *provider-registration-provenance*)))
        (progn
          (provider-registry-remove-source *provider-registry* layer)
          (provider--forget-registration-layer layer))))
  nil)

(-> provider--copy-provenance (hash-table) hash-table)
(defun provider--copy-provenance (provenance)
  "Return a detached copy of the provider registration provenance table."
  (let ((copy (make-hash-table :test (hash-table-test provenance)
                               :size (hash-table-size provenance))))
    (maphash (lambda (key source)
               (setf (gethash key copy) source))
             provenance)
    copy))

(-> provider--registry-snapshot () list)
(defun provider--registry-snapshot ()
  "Return an exact snapshot of provider registration layers and model state."
  (list :registry   (provider-registry-snapshot *provider-registry*)
        :provenance (provider--copy-provenance *provider-registration-provenance*)))

(-> provider--registry-restore (list) null)
(defun provider--registry-restore (snapshot)
  "Restore provider registration layers and model state from SNAPSHOT."
  (unless (and (proper-list-p snapshot)
               (getf snapshot :registry)
               (hash-table-p (getf snapshot :provenance)))
    (error 'configuration-error
           :message "A provider registry snapshot is invalid."))
  (provider-registry-restore *provider-registry* (getf snapshot :registry))
  (let ((provenance (getf snapshot :provenance)))
    (clrhash *provider-registration-provenance*)
    (maphash (lambda (key source)
               (setf (gethash key *provider-registration-provenance*) source))
             provenance))
  nil)
