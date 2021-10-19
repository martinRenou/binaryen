;; NOTE: Assertions have been generated by update_lit_checks.py --all-items and should not be edited.
;; NOTE: This test was ported using port_test.py and could be cleaned up.

;; RUN: foreach %s %t wasm-opt --nominal --unify-itable --remove-unused-module-elements -all -S -o - | filecheck %s
;; remove-unused-module elements makes it easier to read the output as it
;; removes things no longer needed.

(module
  ;; A module with a single itable that contains several categories of
  ;; different sizes, some of them null. The changes to look for:
  ;;
  ;;  * The global will switch to contain a base (of 0, which is where the
  ;;    single itable begins.
  ;;  * A table is added, containing the various functions in the itable in
  ;;    order. No padding happens here, as with a single itable each category
  ;;    is of the size it appears in that itable.
  ;;  * call_ref is replaced by a call_indirect with a proper offset, that
  ;;    takes into account the category as well as the offset in that category.
  ;;

  ;; CHECK:      (type $object (struct_subtype (field $itable i32) data))

  ;; CHECK:      (type $none_=>_none (func_subtype func))
  (type $none_=>_none (func_subtype func))

  (type $itable (array (mut (ref null data))))

  (type $vtable-1 (struct (field (ref $none_=>_none))))
  (type $vtable-2 (struct (field (ref $none_=>_none)) (field (ref $none_=>_none))))
  (type $vtable-3 (struct (field (ref $none_=>_none)) (field (ref $none_=>_none)) (field (ref $none_=>_none))))

  (type $object (struct (field $itable (ref $itable))))

  ;; CHECK:      (type $ref|$object|_=>_none (func_subtype (param (ref $object)) func))

  ;; CHECK:      (type $none_=>_none (func_subtype func))

  ;; CHECK:      (type $none_=>_ref|$object| (func_subtype (result (ref $object)) func))

  ;; CHECK:      (global $itable-1 i32 (i32.const 0))
  (global $itable-1 (ref $itable) (array.init_static $itable
    ;; Category #0, of size 0.
    (ref.null data)
    ;; Category #1, of size 1. This will have base 0.
    (struct.new $vtable-1
      (ref.func $a)
    )
    ;; Category #2, of size 2. This will have base 1.
    (struct.new $vtable-2
      (ref.func $b)
      (ref.func $c)
    )
    ;; Category #3, of size 0.
    (ref.null data)
    ;; Category #4, of size 3. This will have base 3.
    (struct.new $vtable-3
      (ref.func $d)
      (ref.func $e)
      (ref.func $f)
    )
    ;; Category #5, of size 1. This will have base 6.
    (struct.new $vtable-1
      (ref.func $g)
    )
  ))


  ;; CHECK:      (table $unified-table 7 7 funcref)

  ;; CHECK:      (elem (i32.const 0) $a $b $c $d $e $f $g)

  ;; CHECK:      (export "new-1" (func $new-1))

  ;; CHECK:      (export "call-1-0" (func $call-1-0))

  ;; CHECK:      (export "call-2-0" (func $call-2-0))

  ;; CHECK:      (export "call-2-1" (func $call-2-1))

  ;; CHECK:      (export "call-4-0" (func $call-4-0))

  ;; CHECK:      (export "call-4-2" (func $call-4-2))

  ;; CHECK:      (export "call-5-0" (func $call-5-0))

  ;; CHECK:      (func $new-1 (result (ref $object))
  ;; CHECK-NEXT:  (struct.new $object
  ;; CHECK-NEXT:   (global.get $itable-1)
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $new-1 (export "new-1") (result (ref $object))
    (struct.new $object
      (global.get $itable-1)
    )
  )

  ;; CHECK:      (func $call-1-0 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 0)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-1-0 (export "call-1-0") (param $ref (ref $object))
    (call_ref
      ;; Add an offset of 0 in that category. Added to the category base, we get
      ;; 0 which is what will be added before the call_indirect.
      (struct.get $vtable-1 0
        (ref.cast_static $vtable-1
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            ;; Call the first category that has any content, #1. The category
            ;; base is 0.
            (i32.const 1)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $call-2-0 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 1)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-2-0 (export "call-2-0") (param $ref (ref $object))
    (call_ref
      ;; Add an offset of 0 in that category, for a total of 1 added to the
      ;; call_indirect.
      (struct.get $vtable-2 0
        (ref.cast_static $vtable-2
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            ;; Call category #2. It has a base of 1, as there was one item
            ;; in the only category before it.
            (i32.const 2)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $call-2-1 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 2)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-2-1 (export "call-2-1") (param $ref (ref $object))
    (call_ref
      ;; Add an offset of 1 compared to before, for a total of 2.
      (struct.get $vtable-2 1
        (ref.cast_static $vtable-2
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            (i32.const 2)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $call-4-0 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 3)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-4-0 (export "call-4-0") (param $ref (ref $object))
    ;; Call category #4, which has base 3, with offset 0.
    (call_ref
      (struct.get $vtable-3 0
        (ref.cast_static $vtable-3
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            (i32.const 4)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $call-4-2 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 5)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-4-2 (export "call-4-2") (param $ref (ref $object))
    ;; Add an offset of 2, for a total of 5.
    (call_ref
      (struct.get $vtable-3 2
        (ref.cast_static $vtable-3
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            (i32.const 4)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $call-5-0 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 6)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-5-0 (export "call-5-0") (param $ref (ref $object))
    ;; Call category #5, which has base 6, with offset 0.
    (call_ref
      (struct.get $vtable-1 0
        (ref.cast_static $vtable-1
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            (i32.const 5)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $a
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $a)
  ;; CHECK:      (func $b
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $b)
  ;; CHECK:      (func $c
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $c)
  ;; CHECK:      (func $d
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $d)
  ;; CHECK:      (func $e
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $e)
  ;; CHECK:      (func $f
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $f)

  ;; CHECK:      (func $g
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $g)
)

(module
  ;; A module with two itables.
  ;; The final category sizes will be 3 1 3 1 1, and null will appear in the
  ;; table to pad things out wherever needed.

  ;; CHECK:      (type $object (struct_subtype (field $itable i32) data))

  ;; CHECK:      (type $none_=>_none (func_subtype func))
  (type $none_=>_none (func_subtype func))

  (type $itable (array (mut (ref null data))))

  (type $vtable-1 (struct (field (ref $none_=>_none))))
  (type $vtable-2 (struct (field (ref $none_=>_none)) (field (ref $none_=>_none))))
  (type $vtable-3 (struct (field (ref $none_=>_none)) (field (ref $none_=>_none)) (field (ref $none_=>_none))))

  (type $object (struct (field $itable (ref $itable))))

  ;; CHECK:      (type $ref|$object|_=>_none (func_subtype (param (ref $object)) func))

  ;; CHECK:      (type $none_=>_none (func_subtype func))

  ;; CHECK:      (type $none_=>_ref|$object| (func_subtype (result (ref $object)) func))

  ;; CHECK:      (global $itable-1 i32 (i32.const 0))
  (global $itable-1 (ref $itable) (array.init_static $itable
    ;; Category #0, here of size 2. This will have base 0.
    (struct.new $vtable-2
      (ref.func $a)
      (ref.func $b)
    )
    ;; Category #1, here of size 0.
    (ref.null data)
    ;; Category #2, here of size 3. This will have base 4, as category #1 will
    ;; have size 3 overall due to the other itable, and category #1 will have
    ;; size 1 due to the other itable.
    (struct.new $vtable-3
      (ref.func $d)
      (ref.func $e)
      (ref.func $f)
    )
    ;; Category #3, of size 1. This will have base 7.
    (struct.new $vtable-1
      (ref.func $g)
    )
    ;; Nothing for category #4. A null will be emitted instead.
  ))

  ;; CHECK:      (global $itable-2 i32 (i32.const 9))
  (global $itable-2 (ref $itable) (array.init_static $itable
    ;; Category #0, here of size 3. This will have base 0.
    (struct.new $vtable-3
      (ref.func $a-2)
      (ref.func $b-2)
      (ref.func $c-2)
    )
    ;; Category #1, here of size 0. This will have base 3.
    (struct.new $vtable-1
      (ref.func $d-2)
    )
    ;; Category #2, here of size 1. This will have base 4
    (struct.new $vtable-1
      (ref.func $e-2)
    )
    ;; Category #3, of size 0.
    (ref.null data)
    ;; Category #4, of size 2, only present in this itable. This will have base
    ;; 8.
    (struct.new $vtable-1
      (ref.func $f-2)
    )
  ))

  ;; CHECK:      (table $unified-table 18 18 funcref)

  ;; CHECK:      (elem (table $unified-table) (i32.const 0) funcref (ref.func $a) (ref.func $b) (ref.null func) (ref.null func) (ref.func $d) (ref.func $e) (ref.func $f) (ref.func $g) (ref.null func) (ref.func $a-2) (ref.func $b-2) (ref.func $c-2) (ref.func $d-2) (ref.func $e-2) (ref.null func) (ref.null func) (ref.null func) (ref.func $f-2))

  ;; CHECK:      (export "new-1" (func $new-1))

  ;; CHECK:      (export "call-1-1-0" (func $call-1-1-0))

  ;; CHECK:      (export "call-1-2-0" (func $call-1-2-0))

  ;; CHECK:      (export "call-1-2-1" (func $call-1-2-1))

  ;; CHECK:      (export "call-1-3-0" (func $call-1-3-0))

  ;; CHECK:      (export "new-2" (func $new-2))

  ;; CHECK:      (export "call-2-1-0" (func $call-2-1-0))

  ;; CHECK:      (export "call-2-1-1" (func $call-2-1-1))

  ;; CHECK:      (export "call-2-1-2" (func $call-2-1-2))

  ;; CHECK:      (export "call-2-1-4" (func $call-2-1-4))

  ;; CHECK:      (func $new-1 (result (ref $object))
  ;; CHECK-NEXT:  (struct.new $object
  ;; CHECK-NEXT:   (global.get $itable-1)
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $new-1 (export "new-1") (result (ref $object))
    (struct.new $object
      (global.get $itable-1)
    )
  )

  ;; CHECK:      (func $call-1-1-0 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 0)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-1-1-0 (export "call-1-1-0") (param $ref (ref $object))
    (call_ref
      ;; Call itable 1's category #0 with offset 0.
      (struct.get $vtable-2 0
        (ref.cast_static $vtable-2
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            (i32.const 0)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $call-1-2-0 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 4)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-1-2-0 (export "call-1-2-0") (param $ref (ref $object))
    (call_ref
      ;; Call itable 1's category #0 with offset 0.
      (struct.get $vtable-3 0
        (ref.cast_static $vtable-3
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            (i32.const 2)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $call-1-2-1 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 5)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-1-2-1 (export "call-1-2-1") (param $ref (ref $object))
    (call_ref
      ;; Call itable 1's category #0 with offset 1.
      (struct.get $vtable-3 1
        (ref.cast_static $vtable-3
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            (i32.const 2)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $call-1-3-0 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 7)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-1-3-0 (export "call-1-3-0") (param $ref (ref $object))
    (call_ref
      ;; Call itable 1's category #0 with offset 0.
      (struct.get $vtable-1 0
        (ref.cast_static $vtable-1
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            (i32.const 3)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $new-2 (result (ref $object))
  ;; CHECK-NEXT:  (struct.new $object
  ;; CHECK-NEXT:   (global.get $itable-2)
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $new-2 (export "new-2") (result (ref $object))
    (struct.new $object
      (global.get $itable-2)
    )
  )

  ;; CHECK:      (func $call-2-1-0 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 0)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-2-1-0 (export "call-2-1-0") (param $ref (ref $object))
    (call_ref
      ;; Call itable 1's category #0 with offset 0.
      (struct.get $vtable-3 0
        (ref.cast_static $vtable-3
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            (i32.const 0)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $call-2-1-1 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 3)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-2-1-1 (export "call-2-1-1") (param $ref (ref $object))
    (call_ref
      ;; Call itable 1's category #0 with offset 0.
      (struct.get $vtable-1 0
        (ref.cast_static $vtable-1
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            (i32.const 1)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $call-2-1-2 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 4)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-2-1-2 (export "call-2-1-2") (param $ref (ref $object))
    (call_ref
      ;; Call itable 1's category #0 with offset 0.
      (struct.get $vtable-1 0
        (ref.cast_static $vtable-1
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            (i32.const 2)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $call-2-1-4 (param $ref (ref $object))
  ;; CHECK-NEXT:  (call_indirect $unified-table (type $none_=>_none)
  ;; CHECK-NEXT:   (i32.add
  ;; CHECK-NEXT:    (struct.get $object $itable
  ;; CHECK-NEXT:     (local.get $ref)
  ;; CHECK-NEXT:    )
  ;; CHECK-NEXT:    (i32.const 8)
  ;; CHECK-NEXT:   )
  ;; CHECK-NEXT:  )
  ;; CHECK-NEXT: )
  (func $call-2-1-4 (export "call-2-1-4") (param $ref (ref $object))
    (call_ref
      ;; Call itable 1's category #0 with offset 0.
      (struct.get $vtable-1 0
        (ref.cast_static $vtable-1
          (array.get $itable
            (struct.get $object $itable
              (local.get $ref)
            )
            (i32.const 4)
          )
        )
      )
    )
  )

  ;; CHECK:      (func $a
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $a)
  ;; CHECK:      (func $b
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $b)
  (func $c)
  ;; CHECK:      (func $d
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $d)
  ;; CHECK:      (func $e
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $e)
  ;; CHECK:      (func $f
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $f)
  ;; CHECK:      (func $g
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $g)

  ;; CHECK:      (func $a-2
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $a-2)
  ;; CHECK:      (func $b-2
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $b-2)
  ;; CHECK:      (func $c-2
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $c-2)
  ;; CHECK:      (func $d-2
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $d-2)
  ;; CHECK:      (func $e-2
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $e-2)
  ;; CHECK:      (func $f-2
  ;; CHECK-NEXT:  (nop)
  ;; CHECK-NEXT: )
  (func $f-2)
)
