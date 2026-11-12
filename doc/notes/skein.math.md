Require it with an alias:

```skein
(ns my.game
  (:require [skein.math :as m]))
```

The scalar functions take any number: an f32 or f64 keeps its type, and an integer becomes
an f64. The vectors (`vec2`, `vec3`, `vec4`), quaternions (`quat`) and matrices (`mat3`,
`mat4`) are value structs of f32 (DESIGN §9.1): immutable, compared by their fields,
stored inline in arrays, and made from f32 values (`1.0f`). Matrices are column-major,
as GPU APIs expect, and the projections give depth from 0 to 1.

## sin
### Arguments and values
- `x`: a number; an f32 or f64 keeps its type, an integer becomes an f64.
- Returns the sine of `x` radians.

See also: cos, tan, asin

## cos
### Arguments and values
- `x`: a number; an f32 or f64 keeps its type, an integer becomes an f64.
- Returns the cosine of `x` radians.

See also: sin, tan, acos

## tan
### Arguments and values
- `x`: a number; an f32 or f64 keeps its type, an integer becomes an f64.
- Returns the tangent of `x` radians.

See also: sin, cos, atan

## asin
### Arguments and values
- `x`: a number; an f32 or f64 keeps its type, an integer becomes an f64.
- Returns the arc sine, in radians from -π/2 to π/2.

See also: sin, acos

## acos
### Arguments and values
- `x`: a number; an f32 or f64 keeps its type, an integer becomes an f64.
- Returns the arc cosine, in radians from 0 to π.

See also: cos, asin

## atan
### Arguments and values
- `x`: a number; an f32 or f64 keeps its type, an integer becomes an f64.
- Returns the arc tangent, in radians from -π/2 to π/2.

See also: atan2, tan

## exp
### Arguments and values
- `x`: a number; an f32 or f64 keeps its type, an integer becomes an f64.
- Returns e to the power `x`.

See also: log, pow

## log
### Arguments and values
- `x`: a number; an f32 or f64 keeps its type, an integer becomes an f64.
- Returns the natural logarithm of `x`.

See also: exp, pow

## floor
### Arguments and values
- `x`: a number; an f32 or f64 keeps its type, an integer becomes an f64.
- Returns the largest integral value not above `x`, as a float.

See also: ceil, round, trunc

## ceil
### Arguments and values
- `x`: a number; an f32 or f64 keeps its type, an integer becomes an f64.
- Returns the smallest integral value not below `x`, as a float.

See also: floor, round

## round
### Arguments and values
- `x`: a number; an f32 or f64 keeps its type, an integer becomes an f64.
- Returns `x` rounded to the nearest integral value, halves away from zero, as a float.

See also: floor, trunc, int

## trunc
### Arguments and values
- `x`: a number; an f32 or f64 keeps its type, an integer becomes an f64.
- Returns `x` rounded toward zero, as a float.

See also: round, int, quot

## atan2
### Arguments and values
- `y`: the point's y; it comes first, as in C.
- `x`: the point's x.
- Returns its angle from the x axis, from -π to π.

See also: atan, angle

## pow
### Arguments and values
- `x`: the base.
- `y`: the exponent.
- Returns `x` to the power `y`, an f64.

See also: exp, sqrt

## pi
### Arguments and values
- π, an f64.

See also: tau, deg->rad

## tau
### Arguments and values
- 2π, a full turn in radians, an f64.

See also: pi

## sign
### Arguments and values
- `x`: a number.
- Returns -1, 0 or 1, of `x`'s type.

See also: abs

## clamp
### Arguments and values
- `x`: a number.
- `lo`, `hi`: the range's bounds.
- Returns `x`, or the bound it is past.

See also: wrap, min, max

## lerp
### Arguments and values
- `a`, `b`: numbers, or vectors of the same type.
- `t`: 0 gives `a`, 1 gives `b`; values outside extrapolate.
- Returns the point between.

See also: inverse-lerp, remap, slerp, smoothstep

## inverse-lerp
### Arguments and values
- `a`, `b`: the range.
- `x`: a number.
- Returns where `x` is between them: 0 at `a`, 1 at `b`.

See also: lerp, remap

## remap
### Arguments and values
- `x`: a number.
- `a`, `b`: the range it is in.
- `c`, `d`: the range to map it to.
- Returns the number in the second range.

See also: lerp, inverse-lerp

## smoothstep
### Arguments and values
- `edge0`, `edge1`: the range.
- `x`: a number.
- Returns 0 below `edge0`, 1 above `edge1`, and an S curve between.

See also: lerp, clamp

## deg->rad
### Arguments and values
- `d`: an angle in degrees.
- Returns it in radians.

See also: rad->deg

## rad->deg
### Arguments and values
- `r`: an angle in radians.
- Returns it in degrees.

See also: deg->rad

## wrap
### Arguments and values
- `x`: a number.
- `n`: the size of the range, positive.
- Returns `x` wrapped into [0, `n`).

See also: clamp, mod

## approx=
### Arguments and values
- `a`, `b`: numbers.
- `epsilon`: the most they may differ; 1e-5 if not given.
- Returns true if they are that close.

See also: ==

## rand-range
### Arguments and values
- `lo`, `hi`: the range.
- Returns a random f64 from `lo` up to (not including) `hi`.

See also: rand, rand-int

## noise
### Arguments and values
- `x`, `y`, `z`: a point in 2D or 3D.
- Returns Perlin noise there, from -1 to 1: smooth, and the same for the same point.

### Notes
Sample it at several scales and add the results (octaves) for terrain or clouds; it is 0 at integer points.

See also: rand-range

## vec2-x
### Arguments and values
- `s`: a vec2.
- Returns its x field, an f32; `(:x s)` is the same.

See also: vec2, with

## vec2-y
### Arguments and values
- `s`: a vec2.
- Returns its y field, an f32; `(:y s)` is the same.

See also: vec2, with

## vec2?
### Arguments and values
- `x`: any value.
- Returns true if it is a vec2.

See also: vec2

## vec3-x
### Arguments and values
- `s`: a vec3.
- Returns its x field, an f32; `(:x s)` is the same.

See also: vec3, with

## vec3-y
### Arguments and values
- `s`: a vec3.
- Returns its y field, an f32; `(:y s)` is the same.

See also: vec3, with

## vec3-z
### Arguments and values
- `s`: a vec3.
- Returns its z field, an f32; `(:z s)` is the same.

See also: vec3, with

## vec3?
### Arguments and values
- `x`: any value.
- Returns true if it is a vec3.

See also: vec3

## vec4-x
### Arguments and values
- `s`: a vec4.
- Returns its x field, an f32; `(:x s)` is the same.

See also: vec4, with

## vec4-y
### Arguments and values
- `s`: a vec4.
- Returns its y field, an f32; `(:y s)` is the same.

See also: vec4, with

## vec4-z
### Arguments and values
- `s`: a vec4.
- Returns its z field, an f32; `(:z s)` is the same.

See also: vec4, with

## vec4-w
### Arguments and values
- `s`: a vec4.
- Returns its w field, an f32; `(:w s)` is the same.

See also: vec4, with

## vec4?
### Arguments and values
- `x`: any value.
- Returns true if it is a vec4.

See also: vec4

## quat-x
### Arguments and values
- `s`: a quat.
- Returns its x field, an f32; `(:x s)` is the same.

See also: quat, with

## quat-y
### Arguments and values
- `s`: a quat.
- Returns its y field, an f32; `(:y s)` is the same.

See also: quat, with

## quat-z
### Arguments and values
- `s`: a quat.
- Returns its z field, an f32; `(:z s)` is the same.

See also: quat, with

## quat-w
### Arguments and values
- `s`: a quat.
- Returns its w field, an f32; `(:w s)` is the same.

See also: quat, with

## quat?
### Arguments and values
- `x`: any value.
- Returns true if it is a quat.

See also: quat

## mat3-m00
### Arguments and values
- `s`: a mat3.
- Returns the element in column 0, row 0, an f32.

See also: mat3-at, mat3

## mat3-m01
### Arguments and values
- `s`: a mat3.
- Returns the element in column 0, row 1, an f32.

See also: mat3-at, mat3

## mat3-m02
### Arguments and values
- `s`: a mat3.
- Returns the element in column 0, row 2, an f32.

See also: mat3-at, mat3

## mat3-m10
### Arguments and values
- `s`: a mat3.
- Returns the element in column 1, row 0, an f32.

See also: mat3-at, mat3

## mat3-m11
### Arguments and values
- `s`: a mat3.
- Returns the element in column 1, row 1, an f32.

See also: mat3-at, mat3

## mat3-m12
### Arguments and values
- `s`: a mat3.
- Returns the element in column 1, row 2, an f32.

See also: mat3-at, mat3

## mat3-m20
### Arguments and values
- `s`: a mat3.
- Returns the element in column 2, row 0, an f32.

See also: mat3-at, mat3

## mat3-m21
### Arguments and values
- `s`: a mat3.
- Returns the element in column 2, row 1, an f32.

See also: mat3-at, mat3

## mat3-m22
### Arguments and values
- `s`: a mat3.
- Returns the element in column 2, row 2, an f32.

See also: mat3-at, mat3

## mat3?
### Arguments and values
- `x`: any value.
- Returns true if it is a mat3.

See also: mat3

## mat3-at
### Arguments and values
- `m`: a mat3.
- `c`, `r`: a column and a row, from 0.
- Returns that element.

See also: mat3

## mat3-identity
### Arguments and values
- The 3x3 identity matrix.

See also: mat3, m*

## mat4-m00
### Arguments and values
- `s`: a mat4.
- Returns the element in column 0, row 0, an f32.

See also: mat4-at, mat4

## mat4-m01
### Arguments and values
- `s`: a mat4.
- Returns the element in column 0, row 1, an f32.

See also: mat4-at, mat4

## mat4-m02
### Arguments and values
- `s`: a mat4.
- Returns the element in column 0, row 2, an f32.

See also: mat4-at, mat4

## mat4-m03
### Arguments and values
- `s`: a mat4.
- Returns the element in column 0, row 3, an f32.

See also: mat4-at, mat4

## mat4-m10
### Arguments and values
- `s`: a mat4.
- Returns the element in column 1, row 0, an f32.

See also: mat4-at, mat4

## mat4-m11
### Arguments and values
- `s`: a mat4.
- Returns the element in column 1, row 1, an f32.

See also: mat4-at, mat4

## mat4-m12
### Arguments and values
- `s`: a mat4.
- Returns the element in column 1, row 2, an f32.

See also: mat4-at, mat4

## mat4-m13
### Arguments and values
- `s`: a mat4.
- Returns the element in column 1, row 3, an f32.

See also: mat4-at, mat4

## mat4-m20
### Arguments and values
- `s`: a mat4.
- Returns the element in column 2, row 0, an f32.

See also: mat4-at, mat4

## mat4-m21
### Arguments and values
- `s`: a mat4.
- Returns the element in column 2, row 1, an f32.

See also: mat4-at, mat4

## mat4-m22
### Arguments and values
- `s`: a mat4.
- Returns the element in column 2, row 2, an f32.

See also: mat4-at, mat4

## mat4-m23
### Arguments and values
- `s`: a mat4.
- Returns the element in column 2, row 3, an f32.

See also: mat4-at, mat4

## mat4-m30
### Arguments and values
- `s`: a mat4.
- Returns the element in column 3, row 0, an f32.

See also: mat4-at, mat4

## mat4-m31
### Arguments and values
- `s`: a mat4.
- Returns the element in column 3, row 1, an f32.

See also: mat4-at, mat4

## mat4-m32
### Arguments and values
- `s`: a mat4.
- Returns the element in column 3, row 2, an f32.

See also: mat4-at, mat4

## mat4-m33
### Arguments and values
- `s`: a mat4.
- Returns the element in column 3, row 3, an f32.

See also: mat4-at, mat4

## mat4?
### Arguments and values
- `x`: any value.
- Returns true if it is a mat4.

See also: mat4

## mat4-at
### Arguments and values
- `m`: a mat4.
- `c`, `r`: a column and a row, from 0.
- Returns that element.

See also: mat4

## mat4-identity
### Arguments and values
- The 4x4 identity matrix.

See also: mat4, m*

## vec2
### Arguments and values
- `x`, `y`...: the fields, f32 values (`1.0f`), in order; or keywords and values.
- Returns a vec2.

### Notes
Vectors, quaternions and matrices are value structs of f32 (DESIGN §9.1): immutable, compared by their fields, and stored inline in arrays. The constructors take f32 values, so write `1.0f`, or convert with `f32`. The generic functions (`v+`, `dot`, `length`, `lerp`...) take any of the vector types.

See also: vec3, v+, length

## vec3
### Arguments and values
- `x`, `y`...: the fields, f32 values (`1.0f`), in order; or keywords and values.
- Returns a vec3.

See also: vec2, cross, quat-rotate

## vec4
### Arguments and values
- `x`, `y`...: the fields, f32 values (`1.0f`), in order; or keywords and values.
- Returns a vec4.

See also: vec3, transform

## vec2-zero
### Arguments and values
- `(vec2 0 0)`.

See also: vec2

## vec3-zero
### Arguments and values
- `(vec3 0 0 0)`.

See also: vec3

## v+
### Arguments and values
- `a`, `b`: vectors of the same type.
- Returns their sum.

See also: v-, v*

## v-
### Arguments and values
- `a`, `b`: vectors of the same type.
- Returns `a` minus `b`.

See also: v+, negate, distance

## v*
### Arguments and values
- `v`: a vector.
- `k`: a number.
- Returns `v` scaled by `k`.

See also: vdiv, v+

## vdiv
### Arguments and values
- `v`: a vector.
- `k`: a non-zero number.
- Returns `v` divided by `k`.

See also: v*, normalize

## negate
### Arguments and values
- `v`: a vector.
- Returns it pointing the other way.

See also: v-

## dot
### Arguments and values
- `a`, `b`: vectors of the same type.
- Returns their dot product, an f32: positive when they point the same way, 0 when perpendicular.

See also: cross, length

## cross
### Arguments and values
- `a`, `b`: vec3s.
- Returns their cross product, perpendicular to both.

See also: dot

## length
### Arguments and values
- `v`: a vector.
- Returns its length, an f32.

See also: length-sq, normalize, distance

## length-sq
### Arguments and values
- `v`: a vector.
- Returns its squared length, cheaper than `length`.

See also: length

## distance
### Arguments and values
- `a`, `b`: points, vectors of the same type.
- Returns the distance between them.

See also: length, v-

## normalize
### Arguments and values
- `v`: a vector.
- Returns it scaled to length 1, or itself if its length is 0.

See also: length, quat-normalize

## angle
### Arguments and values
- `v`: a vec2.
- Returns its angle from the x axis, in radians.

See also: from-angle, atan2

## from-angle
### Arguments and values
- `angle`: in radians.
- `len`: the length; 1 if not given.
- Returns a vec2.

See also: angle, rotate

## perp
### Arguments and values
- `v`: a vec2.
- Returns it turned a quarter turn counterclockwise.

See also: rotate, cross

## rotate
### Arguments and values
- `v`: a vec2.
- `angle`: in radians, counterclockwise when y points up.
- Returns the rotated vec2.

See also: perp, mat3-rotation, quat-rotate

## mat3
### Arguments and values
- The nine elements, f32 values, column by column: `m00 m01 m02` is the first column.
- Returns a mat3.

### Notes
Matrices are column-major, as GPU APIs expect: element `mCR` is column C, row R, and the translation of an affine mat3 is its last column.

See also: mat3-identity, mat3-translation, m*

## mat4
### Arguments and values
- The sixteen elements, f32 values, column by column.
- Returns a mat4.

See also: mat4-identity, perspective, m*

## mat3-translation
### Arguments and values
- `x`, `y`: numbers.
- Returns the 2D translation, a mat3.

See also: mat3-rotation, mat3-scale, transform-point

## mat3-rotation
### Arguments and values
- `angle`: in radians, counterclockwise.
- Returns the 2D rotation, a mat3.

See also: mat3-translation, rotate

## mat3-scale
### Arguments and values
- `sx`, `sy`: numbers; `sy` is `sx` if not given.
- Returns the 2D scaling, a mat3.

See also: mat3-translation

## mat4-translation
### Arguments and values
- `x`, `y`, `z`: numbers.
- Returns the translation, a mat4.

See also: mat4-rotation, mat4-scale

## mat4-rotation
### Arguments and values
- `q`: a unit quaternion.
- Returns the rotation, a mat4.

See also: quat-from-axis-angle, mat4-translation

## mat4-scale
### Arguments and values
- `sx`, `sy`, `sz`: numbers.
- Returns the scaling, a mat4.

See also: mat4-translation

## m*
### Arguments and values
- `a`, `b`: two matrices of the same size, or two quaternions.
- Returns the product `a`·`b`: applied to a point, `b` acts first.

See also: transform, inverse

## transform
### Arguments and values
- `m`: a mat3 or mat4.
- `v`: a vec3 or vec4 of the same size.
- Returns `m`·`v`.

See also: transform-point, transform-vector

## transform-point
### Arguments and values
- `m`: an affine mat3 or mat4.
- `p`: a vec2 or vec3, a point.
- Returns the transformed point, translation included.

See also: transform-vector, transform

## transform-vector
### Arguments and values
- `m`: an affine mat3 or mat4.
- `v`: a vec2 or vec3, a direction.
- Returns it transformed, translation ignored.

See also: transform-point

## transpose
### Arguments and values
- `m`: a matrix.
- Returns its transpose.

See also: inverse

## determinant
### Arguments and values
- `m`: a matrix.
- Returns its determinant, an f32 as the matrix's elements are.

See also: inverse

## inverse
### Arguments and values
- `m`: a matrix or a unit quaternion.
- Returns its inverse, or nil for a matrix that has none.

See also: determinant, conjugate, m*

## perspective
### Arguments and values
- `fov-y`: the vertical field of view, in radians.
- `aspect`: width / height.
- `near`, `far`: the clipping planes' distances, positive.
- Returns a right-handed projection to clip space with depth from 0 to 1, as Vulkan, Metal and SDL's GPU API use.

See also: ortho, look-at

## ortho
### Arguments and values
- `left`, `right`, `bottom`, `top`, `near`, `far`: the box to see.
- Returns an orthographic projection to clip space, depth from 0 to 1.

See also: perspective

## look-at
### Arguments and values
- `eye`: the camera's position, a vec3.
- `target`: the point it looks at.
- `up`: which way is up.
- Returns a right-handed view matrix.

See also: perspective, mat4-translation

## quat
### Arguments and values
- `x`, `y`, `z`: the vector part, f32 values.
- `w`: the scalar part.
- Returns a quaternion.

See also: quat-from-axis-angle, quat-identity

## quat-identity
### Arguments and values
- The rotation that does nothing, `(quat 0 0 0 1)`.

See also: quat

## quat-from-axis-angle
### Arguments and values
- `axis`: a vec3, which needn't be normalized.
- `angle`: in radians.
- Returns the rotation, a unit quaternion.

See also: quat-rotate, mat4-rotation, slerp

## quat-rotate
### Arguments and values
- `q`: a unit quaternion.
- `v`: a vec3.
- Returns `v` rotated.

See also: quat-from-axis-angle, rotate

## quat-normalize
### Arguments and values
- `q`: a quaternion.
- Returns it scaled to length 1.

See also: normalize

## conjugate
### Arguments and values
- `q`: a unit quaternion.
- Returns its inverse, the opposite rotation.

See also: inverse

## slerp
### Arguments and values
- `a`, `b`: unit quaternions.
- `t`: 0 gives `a`, 1 gives `b`.
- Returns the rotation between, at a constant angular speed.

See also: lerp, quat-from-axis-angle

