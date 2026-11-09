;;;; Core IR node definitions (DESIGN §5.1, docs/CORE-IR.md).

(defpackage #:skein.ir
  (:use #:cl)
  (:documentation "Core IR: the small language the expander produces and backends consume."))
