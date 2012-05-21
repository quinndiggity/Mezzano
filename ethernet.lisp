(defpackage #:system.networking
  (:use #:cl #:sys.int)
  (:nicknames #:sys.net)
  (:export register-nic
           ethernet-mac
           transmit-packet
           receive-packet
           arp-lookup
           copy-packet packet-length))

(in-package #:sys.net)

(defvar *cards* '())

(defun register-nic (nic)
  (push nic *cards*))

(defgeneric ethernet-mac (nic))

(defun reduce (function list)
  (cond ((null list) (funcall function))
        ((null (rest list)) (first list))
        (t (let ((x (funcall function (first list) (second list))))
             (dolist (i (cddr list) x)
               (setf x (funcall function x i)))))))

(defun packet-length (packet)
  (reduce '+ (mapcar 'length packet)))

(defun copy-packet (buffer packet &optional (buffer-start 0))
  (dolist (p packet)
    (dotimes (i (length p))
      (setf (aref buffer buffer-start) (aref p i))
      (incf buffer-start))))

(defun ub16ref/be (vector index)
  (logior (ash (aref vector index) 8)
	  (aref vector (1+ index))))
(defun (setf ub16ref/be) (value vector index)
  (setf (aref vector index) (ash value -8)
	(aref vector (1+ index)) (logand value #xFF))
  value)

(defun ub16ref/le (vector index)
  (logior (aref vector index)
	  (ash (aref vector (1+ index)) 8)))
(defun (setf ub16ref/le) (value vector index)
  (setf (aref vector index) (logand value #xFF)
	(aref vector (1+ index)) (ash value -8))
  value)

(defun ub32ref/be (vector index)
  (logior (ash (aref vector index) 24)
	  (ash (aref vector (+ index 1)) 16)
	  (ash (aref vector (+ index 2)) 8)
	  (aref vector (+ index 3))))
(defun (setf ub32ref/be) (value vector index)
  (setf (aref vector index) (ash value -24)
	(aref vector (+ index 1)) (logand (ash value -16) #xFF)
	(aref vector (+ index 2)) (logand (ash value -8) #xFF)
	(aref vector (+ index 3)) (logand value #xFF))
  value)

(defun ub32ref/le (vector index)
  (logior (aref vector index)
	  (ash (aref vector (+ index 1)) 8)
	  (ash (aref vector (+ index 2)) 16)
	  (ash (aref vector (+ index 3)) 24)))
(defun (setf ub32ref/le) (value vector index)
  (setf (aref vector index) (logand value #xFF)
	(aref vector (+ index 1)) (logand (ash value -8) #xFF)
	(aref vector (+ index 2)) (logand (ash value -16) #xFF)
	(aref vector (+ index 3)) (ash value -24))
  value)

(defconstant +ethertype-ipv4+ #x0800)
(defconstant +ethertype-arp+  #x0806)
(defconstant +ethertype-ipv6+ #x86DD)

(defconstant +arp-op-request+ 1)
(defconstant +arp-op-reply+ 2)

(defconstant +arp-hrd-ethernet+ 1)

(defconstant +ip-protocol-icmp+ 1)
(defconstant +ip-protocol-igmp+ 2)
(defconstant +ip-protocol-tcp+ 6)
(defconstant +ip-protocol-udp+ 17)

(defconstant +tcp4-flag-fin+ #b00000001)
(defconstant +tcp4-flag-syn+ #b00000010)
(defconstant +tcp4-flag-rst+ #b00000100)
(defconstant +tcp4-flag-psh+ #b00001000)
(defconstant +tcp4-flag-ack+ #b00010000)

(defconstant +icmp-echo-reply+ 0)
(defconstant +icmp-echo-request+ 8)
(defconstant +icmp-destination-unreachable+ 3)
(defconstant +icmp-time-exceeded+ 11)
(defconstant +icmp-parameter-problem+ 12)

;;; Destination unreachable codes.
(defconstant +icmp-code-net-unreachable+ 0)
(defconstant +icmp-code-host-unreachable+ 1)
(defconstant +icmp-code-protocol-unreachable+ 2)
(defconstant +icmp-code-port-unreachable+ 3)
(defconstant +icmp-code-fragmentation-needed+ 4)
(defconstant +icmp-code-source-route-failed+ 5)

;; Time exceeded codes.
(defconstant +icmp-code-ttl-exceeded+ 0)
(defconstant +icmp-code-fragment-timeout+ 1)

(defparameter *ethernet-broadcast* (make-array 6 :element-type '(unsigned-byte 8)
                                               :initial-element #xFF))

(defparameter *ipv4-interfaces* '())

(defun ifup (nic address)
  (setf (getf *ipv4-interfaces* nic) address))

(defun ifdown (nic)
  (setf (getf *ipv4-interfaces* nic) nil))

(defun ipv4-interface-address (nic)
  (or (getf *ipv4-interfaces* nic)
      (error "No IPv4 address for interface ~S." nic)))

;;; The ARP table is a list of lists. Each list holds:
;;; (protocol-type protocol-address network-address age)
(defvar *arp-table* nil)

(defun arp-receive (interface packet)
  (let* ((htype (ub16ref/be packet 14))
	 (ptype (ub16ref/be packet 16))
	 (hlen (aref packet 18))
	 (plen (aref packet 19))
	 (oper (ub16ref/be packet 20))
	 (sha-start 22)
	 (spa-start (+ sha-start hlen))
	 (tha-start (+ spa-start plen))
	 (tpa-start (+ tha-start hlen))
	 (packet-end (+ tpa-start plen))
	 (merge-flag nil))
    ;; Ethernet hardware type and IPv4.
    (when (and (eql htype +arp-hrd-ethernet+) (eql hlen 6)
	       (eql ptype +ethertype-ipv4+) (eql plen 4))
      (let ((spa (ub32ref/be packet spa-start))
	    (tpa (ub32ref/be packet tpa-start)))
	;; If the pair <protocol type, sender protocol address> is
	;; already in my translation table, update the sender
	;; hardware address field of the entry with the new
	;; information in the packet and set Merge_flag to true.
	(dolist (e *arp-table*)
	  (when (and (eql (first e) ptype)
		     (eql (second e) spa))
	    (setf (third e) (subseq packet sha-start spa-start)
		  merge-flag t)
	    (return)))
	(when (eql tpa (ipv4-interface-address interface))
	  (unless merge-flag
	    (push (list ptype spa (subseq packet sha-start spa-start) 0) *arp-table*))
	  (when (eql oper +arp-op-request+)
	    ;; Copy source hardware address to dest MAC and target h/w address.
	    (dotimes (i 6)
	      (setf (aref packet i) (aref packet (+ sha-start i))
		    (aref packet (+ tha-start i)) (aref packet (+ sha-start i))))
	    ;; Copy source protocol address to target protocol address.
	    (dotimes (i plen)
	      (setf (aref packet (+ tpa-start i)) (aref packet (+ spa-start i))))
	    ;; Set source hardware address and source MAC to the interface's MAC.
	    (let ((mac (ethernet-mac interface)))
	      (dotimes (i 6)
		(setf (aref packet (+ 6 i)) (aref mac i)
		      (aref packet (+ sha-start i)) (aref mac i))))
	    (setf (ub32ref/be packet spa-start) (ipv4-interface-address interface)
		  (ub16ref/be packet 20) +arp-op-reply+)
	    (transmit-packet interface (list packet))))))))

(defun send-arp (interface ptype address)
  "Send an ARP packet out onto the wire."
  (unless (eql ptype +ethertype-ipv4+)
    (error "Unsupported protocol type ~S" ptype))
  (let ((packet (make-array 42 :element-type '(unsigned-byte 8)))
	(mac (ethernet-mac interface)))
    ;; Fill in various hardware address fields.
    (dotimes (i 6)
      ;; Ethernet destination.
      (setf (aref packet i) #xFF
	    ;; Ethernet source.
	    (aref packet (+ 6 i)) (aref mac i)
	    ;; ARP source hardware address.
	    (aref packet (+ 22 i)) (aref mac i)))
    ;; Set the source and target protocol addresses.
    (setf (ub32ref/be packet 28) (ipv4-interface-address interface)
	  (ub32ref/be packet 38) address
	  ;; Various other fields.
	  (ub16ref/be packet 12) +ethertype-arp+
	  (ub16ref/be packet 14) +arp-hrd-ethernet+
	  (ub16ref/be packet 16) +ethertype-ipv4+
	  (aref packet 18) 6
	  (aref packet 19) 4
	  (ub16ref/be packet 20) +arp-op-request+)
    (transmit-packet interface (list packet))))

(defun arp-lookup (interface ptype address)
  "Convert ADDRESS to an Ethernet address."
  ;; Scan the ARP table.
  (dolist (e *arp-table*)
    (when (and (eql (first e) ptype)
	       (eql (second e) address))
      (return-from arp-lookup (third e))))
  (dotimes (attempt 3)
    (send-arp interface ptype address)
    ;; FIXME: better timeout.
    (sys.int::process-wait-with-timeout "ARP Lookup" 200
			       (lambda ()
				 (dolist (e *arp-table* nil)
				   (when (and (eql (first e) ptype)
					      (eql (second e) address))
				     (return t)))))
    (dolist (e *arp-table*)
      (when (and (eql (first e) ptype)
		 (eql (second e) address))
	(return-from arp-lookup (third e))))))

(defstruct tcp-connection
  state
  local-port
  remote-port
  remote-ip
  s-next
  r-next
  window-size
  (max-seg-size 1000)
  rx-data)

(defvar *raw-packet-hooks* nil)
(defvar *tcp-connections* nil)
(defvar *allocated-tcp-ports* nil)

(defun %receive-packet (interface packet)
  (dolist (hook *raw-packet-hooks*)
    (funcall hook interface packet))
  (let ((ethertype (ub16ref/be packet 12)))
    (cond
      ((eql ethertype +ethertype-arp+)
       (arp-receive interface packet))
      ((eql ethertype +ethertype-ipv4+)
       ;; Should check the IP header checksum here...
       (let ((header-length (* (ldb (byte 4 0) (aref packet 14)) 4))
             (total-length (ub16ref/be packet 16))
             (protocol (aref packet (+ 14 9))))
         (cond
           ((eql protocol +ip-protocol-tcp+)
            (let ((remote-port (ub16ref/be packet (+ 14 header-length)))
                  (local-port (ub16ref/be packet (+ 14 header-length 2))))
              (dolist (connection *tcp-connections*
                       (format t "No connection for TCP ~S ~S.~%" remote-port local-port))
                (when (and (eql (tcp-connection-remote-port connection) remote-port)
                           (eql (tcp-connection-local-port connection) local-port))
                  (tcp4-receive connection packet (+ 14 header-length) (+ 14 total-length))
                  (return)))))
           (t (format t "Unknown IPv4 protocol ~S ~S.~%" protocol packet)))))
      (t (format t "Unknown ethertype ~S ~S.~%" ethertype packet)))))

(define-condition drop-packet () ())

(defvar *pending-packets* '())

(defun ethernet-worker ()
  (loop (sys.int::process-wait "Ethernet worker"
                               (lambda () (not (endp *pending-packets*))))
     (with-simple-restart (abort "Ignore this packet.")
       (handler-case (apply '%receive-packet (pop *pending-packets*))
         (drop-packet ())))))

(defvar *ethernet-process* (make-instance 'sys.int::process :name "Ethernet worker"))
(sys.int::process-preset *ethernet-process* #'ethernet-worker)
(sys.int::process-enable *ethernet-process*)

(defun receive-packet (interface packet)
  (push (list interface packet) *pending-packets*))

(defun detach-tcp-connection (connection)
  (setf *tcp-connections* (remove connection *tcp-connections*))
  (setf *allocated-tcp-ports* (remove (tcp-connection-local-port connection) *allocated-tcp-ports*)))

(defun tcp4-receive (connection packet &optional (start 0) end)
  (unless end (setf end (length packet)))
  (let* ((seq (ub32ref/be packet (+ start 4)))
	 (ack (ub32ref/be packet (+ start 8)))
	 (flags (aref packet (+ start 13)))
	 (header-length (* (ash (aref packet (+ start 12)) -4) 4))
	 (data-length (- end (+ start header-length))))
    (case (tcp-connection-state connection)
      (:syn-sent
       (if (and (logtest flags +tcp4-flag-ack+)
		(logtest flags +tcp4-flag-syn+)
		(eql ack (tcp-connection-s-next connection)))
	   (progn
	     (setf (tcp-connection-state connection) :established
		   (tcp-connection-r-next connection) (logand (1+ seq) #xFFFFFFFF))
	     (tcp4-send-packet connection ack (tcp-connection-r-next connection) nil))
	   (progn
	     (setf (tcp-connection-state connection) :closed)
	     (detach-tcp-connection connection)
	     (tcp4-send-packet connection 0 0 nil :ack-p nil :rst-p t)
	     (format t "TCP: got ack ~S, wanted ~S. Flags ~B~%" ack (tcp-connection-s-next connection) flags))))
      (:established
       ;; Ignore out-of-order packets.
       (when (eql seq (tcp-connection-r-next connection))
	 (unless (eql data-length 0)
	   ;; Send data to the user layer
	   (if (tcp-connection-rx-data connection)
	       (setf (cdr (last (tcp-connection-rx-data connection))) (list (list packet (+ start header-length) end)))
	       (setf (tcp-connection-rx-data connection) (list (list packet (+ start header-length) end))))
	   (setf (tcp-connection-r-next connection)
		 (logand (+ (tcp-connection-r-next connection) data-length)
			 #xFFFFFFFF)))
	 (cond
	   ((logtest flags +tcp4-flag-fin+)
	    ;; Always ack FIN packets.
	    (setf (tcp-connection-state connection) :closing
		  (tcp-connection-r-next connection)
		  (logand (+ (tcp-connection-r-next connection) 1)
			  #xFFFFFFFF))
	    (tcp4-send-packet connection
			      (tcp-connection-s-next connection)
			      (tcp-connection-r-next connection)
			      nil
			      :fin-p t))
	   ((not (eql data-length 0))
	    (tcp4-send-packet connection
			      (tcp-connection-s-next connection)
			      (tcp-connection-r-next connection)
			      nil)))))
      (:closing
       (cond ((logtest flags +tcp4-flag-ack+))
             ((logtest flags +tcp4-flag-fin+)
              (tcp4-send-packet connection
                                (tcp-connection-s-next connection)
                                (tcp-connection-r-next connection)
                                nil
                                :ack-p t
                                :fin-p t)))
       (detach-tcp-connection connection)
       (setf (tcp-connection-state connection) :closed))
      (:closed
       (detach-tcp-connection connection))
      (t (tcp4-send-packet connection 0 0 nil :ack-p nil :rst-p t)
	 (format t "TCP: Unknown connection state ~S ~S ~S.~%" (tcp-connection-state connection) start packet)
	 (detach-tcp-connection connection)
	 (setf (tcp-connection-state connection) :closed)))))

(defun tcp4-send-packet (connection seq ack data &key (ack-p t) psh-p rst-p syn-p fin-p)
  (multiple-value-bind (ethernet-mac interface)
      (ipv4-route (tcp-connection-remote-ip connection))
    (when (and ethernet-mac interface)
      (let* ((source (ipv4-interface-address interface))
	     (source-port (tcp-connection-local-port connection))
	     (packet (assemble-tcp4-packet source source-port
					   (tcp-connection-remote-ip connection)
					   (tcp-connection-remote-port connection)
					   seq ack
					   (tcp-connection-window-size connection)
					   data
					   :ack-p ack-p
					   :psh-p psh-p
					   :rst-p rst-p
					   :syn-p syn-p
					   :fin-p fin-p)))
	(transmit-ethernet-packet interface ethernet-mac +ethertype-ipv4+ packet)))))

(defun ipv4-route (destination)
  "Return the interface and destination mac for the destination IP address."
  (let ((default-route nil))
    (dolist (route *routing-table*)
      (cond ((null (first route))
	     (setf default-route route))
	    ((eql (logand destination (third route)) (first route))
	     (return-from ipv4-route
	       (values (arp-lookup (fourth route) +ethertype-ipv4+ destination)
		       (fourth route))))))
    (when default-route
      (values (arp-lookup (fourth default-route) +ethertype-ipv4+ (second default-route))
	      (fourth default-route)))))

(defun make-ipv4-address (a b c d)
  (logior (ash a 24)
	  (ash b 16)
	  (ash c 8)
	  d))

(defun compute-ip-partial-checksum (buffer &optional (start 0) end (initial 0))
  ;; From RFC 1071.
  (let ((total initial))
    (setf end (or end (length buffer)))
    (when (oddp (- end start))
      (decf end)
      (incf total (ash (aref buffer end) 8)))
    (do ((i start (+ i 2)))
	((>= i end))
      (incf total (ub16ref/be buffer i)))
    total))

(defun compute-ip-checksum (buffer &optional (start 0) end (initial 0))
  (let ((total (compute-ip-partial-checksum buffer start end initial)))
    (do ()
	((not (logtest total #xFFFF0000)))
      (setf total (+ (logand total #xFFFF)
		     (ash total -16))))
    (logand (lognot total) #xFFFF)))

(defun compute-ip-pseudo-header-partial-checksum (src-ip dst-ip protocol length)
  (+ (logand src-ip #xFFFF)
     (logand (ash src-ip -16) #xFFFF)
     (logand dst-ip #xFFFF)
     (logand (ash dst-ip -16) #xFFFF)
     protocol
     length))

(defun transmit-udp4-packet (destination source-port destination-port packet)
  (let* ((header (make-array 8 :element-type '(unsigned-byte 8)))
	 (packet (cons header packet)))
    (setf (ub16ref/be header 0) source-port
	  (ub16ref/be header 2) destination-port
	  (ub16ref/be header 4) (packet-length packet)
	  (ub16ref/be header 6) 0)
    (transmit-ipv4-packet destination +ip-protocol-udp+ packet)))

(defun assemble-tcp4-packet (src-ip src-port dst-ip dst-port seq-num ack-num window payload
			     &key (ack-p t) psh-p rst-p syn-p fin-p)
  "Build a full TCP & IP header."
  (let* ((checksum 0)
	 (payload-size (length payload))
	 (header (make-array 44 :element-type '(unsigned-byte 8)
			     :initial-element 0))
	 (packet (list header payload)))
    ;; Assemble the IP header.
    (setf
     ;; Version (4) and header length (5 32-bit words).
     (aref header 0) #x45
     ;; Type of service, normal packet.
     (aref header 1) #x00
     ;; Total length.
     (ub16ref/be header 2) (+ payload-size 44)
     ;; Packet ID(?).
     (ub16ref/be header 4) 0
     ;; Flags & fragment offset.
     (ub16ref/be header 6) 0
     ;; Time-to-Live. ### What should this be set to?
     (aref header 8) #xFF
     ;; Protocol.
     (aref header 9) +ip-protocol-tcp+
     ;; Source address.
     (ub32ref/be header 12) src-ip
     ;; Destination address.
     (ub32ref/be header 16) dst-ip
     ;; IP header checksum.
     (ub16ref/be header 10) (compute-ip-checksum header 0 20))
    ;; Assemble the TCP header.
    (setf
     (ub16ref/be header 20) src-port
     (ub16ref/be header 22) dst-port
     (ub32ref/be header 24) seq-num
     (ub32ref/be header 28) ack-num
     ;; Data offset/header length (6 32-bit words).
     (aref header 32) #x60
     ;; Flags.
     (aref header 33) (logior (if fin-p +tcp4-flag-fin+ 0)
			      (if syn-p +tcp4-flag-syn+ 0)
			      (if rst-p +tcp4-flag-rst+ 0)
			      (if psh-p +tcp4-flag-psh+ 0)
			      (if ack-p +tcp4-flag-ack+ 0))
     ;; Window.
     (ub16ref/be header 34) window)
    ;; Compute the final checksum.
    (setf checksum (compute-ip-pseudo-header-partial-checksum src-ip dst-ip +ip-protocol-tcp+ (+ 24 payload-size)))
    (setf checksum (compute-ip-partial-checksum header 20 nil checksum))
    (setf checksum (compute-ip-checksum payload 0 nil checksum))
    (setf (ub16ref/be header 36) checksum)
    packet))

(defun allocate-local-tcp-port ()
  (do ()
      (nil)
    (let ((port (+ (random 32768) 32768)))
      (unless (find port *allocated-tcp-ports*)
	(push port *allocated-tcp-ports*)
	(return port)))))

(defun random (limit &optional random-state)
  0)

(defun tcp-connect (ip port)
  (let* ((source-port (allocate-local-tcp-port))
	 (seq (random #x100000000))
	 (connection (make-tcp-connection :state :syn-sent
					  :local-port source-port
					  :remote-port port
					  :remote-ip ip
					  :s-next (logand #xFFFFFFFF (1+ seq))
					  :r-next 0
					  :window-size 8192)))
    (push connection *tcp-connections*)
    (tcp4-send-packet connection seq 0 nil :ack-p nil :syn-p t)
    (when (sys.int::process-wait-with-timeout "TCP connect" 100
				     (lambda () (not (eql (tcp-connection-state connection) :syn-sent))))
      (setf (tcp-connection-state connection) :closed))
    connection))

(defun tcp-send (connection data &optional (start 0) end)
  (when (eql (tcp-connection-state connection) :established)
    (setf end (or end (length data)))
    (let ((mss (tcp-connection-max-seg-size connection)))
      (cond
        ((>= start end))
        ((> (- end start) mss)
         ;; Send multiple packets.
         (error "Packet too large..."))
        (t ;; Send one packet.
         (let ((s-next (tcp-connection-s-next connection)))
           (setf (tcp-connection-s-next connection)
                 (logand (+ s-next (- end start))
                         #xFFFFFFFF))
           (tcp4-send-packet connection s-next
                             (tcp-connection-r-next connection)
                             (if (and (eql start 0)
                                      (eql end (length data)))
                                 data
                                 (subseq data start end))
                             :psh-p t)))))))

(defvar *test-message* #(#x47 #x45 #x54 #x20 #x2F #x0D #x0A #x0D #x0A))

(defun send-ping (destination &optional (identifier 0) (sequence-number 0) payload)
  (let ((packet (make-array (+ 8 (if payload (length payload) 56)))))
    (setf
     ;; Type.
     (aref packet 0) +icmp-echo-request+
     ;; Code.
     (aref packet 1) 0
     ;; Checksum.
     (ub16ref/be packet 2) 0
     ;; Identifier.
     (ub16ref/be packet 4) identifier
     ;; Sequence number.
     (ub16ref/be packet 6) sequence-number)
    (if payload
	(dotimes (i (length payload))
	  (setf (aref packet (+ 8 i)) (aref payload i)))
	(dotimes (i 56)
	  (setf (aref packet (+ 8 i)) i)))
    (setf (ub16ref/be packet 2) (compute-ip-checksum packet))
    (transmit-ipv4-packet destination +ip-protocol-icmp+ (list packet))))

(defmacro with-raw-packet-hook (function &body body)
  (let ((old-value (gensym)))
    `(let ((,old-value *raw-packet-hooks*))
       (unwind-protect (progn (setf *raw-packet-hooks* (cons ,function *raw-packet-hooks*))
                              ,@body)
         (setf *raw-packet-hooks* ,old-value)))))

(defun ethertype (packet)
  (ub16ref/be packet 12))

(defun ipv4-protocol (packet)
  (aref packet (+ 14 9)))

(defun ipv4-source (packet)
  (ub32ref/be packet (+ 14 12)))

(defun ping4-identifier (packet)
  (let ((header-length (* (ldb (byte 4 0) (aref packet 14)) 4)))
    (ub16ref/be packet (+ 14 header-length 4))))

(defun ping4-sequence-number (packet)
  (let ((header-length (* (ldb (byte 4 0) (aref packet 14)) 4)))
    (ub16ref/be packet (+ 14 header-length 6))))

(defun ping-host (host &optional (count 4))
  (let ((in-flight-pings nil)
        (identifier 1234))
    (with-raw-packet-hook
      (lambda (interface p)
        (declare (ignore interface))
        (when (and (eql (ethertype p) +ethertype-ipv4+)
                   (eql (ipv4-protocol p) +ip-protocol-icmp+)
                   (eql (ipv4-source p) host)
                   (eql (ping4-identifier p) identifier)
                   (find (ping4-sequence-number p) in-flight-pings))
          (setf in-flight-pings (delete (ping4-sequence-number p) in-flight-pings))
          (format t "Pong ~S.~%" (ping4-sequence-number p))
          (signal (make-condition 'drop-packet))))
      (dotimes (i count)
        (push i in-flight-pings)
        (send-ping host identifier i))
      (sys.int::process-wait-with-timeout "Ping" 10 (lambda () (null in-flight-pings)))
      (when in-flight-pings
        (format t "~S pings still in-flight.~%" (length in-flight-pings))))))

(defun transmit-ipv4-packet (destination protocol payload)
  (multiple-value-bind (ethernet-mac interface)
      (ipv4-route destination)
    (when (and ethernet-mac interface)
      (let* ((source (or (ipv4-interface-address interface) #x00000000))
	     (ip-header (make-array 20 :element-type '(unsigned-byte 8)
				    :initial-element 0))
	     (packet (cons ip-header payload)))
	(setf
	 ;; Version (4) and header length (5 32-bit words).
	 (aref ip-header 0) #x45
	 ;; Type of service, normal packet.
	 (aref ip-header 1) #x00
	 ;; Total length.
	 (ub16ref/be ip-header 2) (packet-length packet)
	 ;; Packet ID(?).
	 (ub16ref/be ip-header 4) 0
	 ;; Flags & fragment offset.
	 (ub16ref/be ip-header 6) 0
	 ;; Time-to-Live. ### What should this be set to?
	 (aref ip-header 8) #xFF
	 ;; Protocol.
	 (aref ip-header 9) protocol
	 ;; Source address.
	 (ub32ref/be ip-header 12) source
	 ;; Destination address.
	 (ub32ref/be ip-header 16) destination
	 ;; Header checksum.
	 (ub16ref/be ip-header 10) (compute-ip-checksum ip-header))
	(format t "TX packet ~S ~S ~S ~S ~S~%"
		source destination ethernet-mac interface
		packet)
	(transmit-ethernet-packet interface ethernet-mac +ethertype-ipv4+ packet)))))

(defun transmit-ethernet-packet (interface destination ethertype packet)
  (let* ((ethernet-header (make-array 14 :element-type '(unsigned-byte 8)))
	 (packet (cons ethernet-header packet))
	 (source (ethernet-mac interface)))
    (dotimes (i 6)
      (setf (aref ethernet-header i) (aref destination i)
	    (aref ethernet-header (+ i 6)) (aref source i)))
    (setf (ub16ref/be ethernet-header 12) ethertype)
    (transmit-packet interface packet)))

;;; (network gateway netmask interface)
(defvar *routing-table* nil)

(defgeneric transmit-packet (nic packet-descriptor))

(defclass tcp-stream (sys.int::stream-object)
  ((connection :initarg :connection)
   (current-packet :initform nil)))

(defun encode-utf8-string (sequence start end)
  (let ((bytes (make-array (- end start)
                           :element-type '(unsigned-byte 8)
                           :adjustable t
                           :fill-pointer 0)))
    (dotimes (i (- end start))
      (let ((c (char sequence (+ start i))))
        (vector-push-extend (char-code c) bytes)))
    bytes))

(defun refill-tcp-stream-buffer (stream)
  (let ((connection (slot-value stream 'connection)))
    (when (and (null (slot-value stream 'current-packet))
               (tcp-connection-rx-data connection))
      (setf (slot-value stream 'current-packet) (pop (tcp-connection-rx-data connection))))))

(defun tcp-connection-closed-p (stream)
  (let ((connection (slot-value stream 'connection)))
    (refill-tcp-stream-buffer stream)
    (and (null (slot-value stream 'current-packet))
         (not (eql (tcp-connection-state connection) :established)))))

(defmethod sys.int::stream-listen ((stream tcp-stream))
  (refill-tcp-stream-buffer stream)
  (not (null (slot-value stream 'current-packet))))

(defmethod sys.int::stream-read-byte ((stream tcp-stream))
  (let ((connection (slot-value stream 'connection)))
    ;; Refill the packet buffer.
    (when (null (slot-value stream 'current-packet))
      (sys.int::process-wait "TCP read" (lambda ()
                                          (or (tcp-connection-rx-data connection)
                                              (not (eql (tcp-connection-state connection) :established)))))
      (when (and (null (tcp-connection-rx-data connection))
		 (not (eql (tcp-connection-state connection) :established)))
	(return-from sys.int::stream-read-byte nil))
      (setf (slot-value stream 'current-packet) (first (tcp-connection-rx-data connection))
	    (tcp-connection-rx-data connection) (cdr (tcp-connection-rx-data connection))))
    (let* ((packet (slot-value stream 'current-packet))
	   (byte (aref (first packet) (second packet))))
      (when (>= (incf (second packet)) (third packet))
	(setf (slot-value stream 'current-packet) nil))
      byte)))

(defmethod sys.int::stream-read-char ((stream tcp-stream))
  (let ((leader (read-byte stream nil)))
    (when leader
      (when (eql leader #x0D)
        (read-byte stream nil)
        (setf leader #x0A))
      (code-char leader))))

(defmethod sys.int::stream-write-byte (byte (stream tcp-stream))
  (let ((ary (make-array 1 :element-type '(unsigned-byte 8)
                         :initial-element byte)))
    (tcp-send (slot-value stream 'connection) ary)))

(defmethod sys.int::stream-write-sequence (sequence (stream tcp-stream) start end)
  (cond ((stringp sequence)
         (setf sequence (encode-utf8-string sequence start end)))
        ((not (and (zerop start)
                   (eql end (length sequence))))
         (setf sequence (subseq sequence start end))))
  (tcp-send (slot-value stream 'connection) sequence))

(defmethod sys.int::stream-write-char (character (stream tcp-stream))
  (when (eql character #\Newline)
    (write-byte #x0D stream))
  (write-byte (char-code character) stream))

(defmethod sys.int::stream-close ((stream tcp-stream) abort)
  (let* ((connection (slot-value stream 'connection)))
    (setf (tcp-connection-state connection) :closing)
    (tcp4-send-packet connection
                      (tcp-connection-s-next connection)
                      (tcp-connection-r-next connection)
                      nil
                      :fin-p t
                      ;; Shouldn't actually rst here...
                      :rst-p t)))

(defun ethernet-init ()
  (setf *cards* '()
        *arp-table* '())
  (dolist (x *tcp-connections*)
    (detach-tcp-connection x)))
(sys.int::add-hook 'sys.int::*early-initialize-hook* 'ethernet-init)
