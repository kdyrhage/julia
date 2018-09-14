# This file is a part of Julia. License is MIT: https://julialang.org/license

module MPFR

export
    BigFloat,
    setprecision

import
    .Base: *, +, -, /, <, <=, ==, >, >=, ^, ceil, cmp, convert, copysign, div,
        inv, exp, exp2, exponent, factorial, floor, fma, hypot, isinteger,
        isfinite, isinf, isnan, ldexp, log, log2, log10, max, min, mod, modf,
        nextfloat, prevfloat, promote_rule, rem, rem2pi, round, show, float,
        sum, sqrt, string, print, trunc, precision, exp10, expm1,
        log1p,
        eps, signbit, sin, cos, sincos, tan, sec, csc, cot, acos, asin, atan,
        cosh, sinh, tanh, sech, csch, coth, acosh, asinh, atanh,
        cbrt, typemax, typemin, unsafe_trunc, floatmin, floatmax, rounding,
        setrounding, maxintfloat, widen, significand, frexp, tryparse, iszero,
        isone, big, _string_n

import .Base.Rounding: rounding_raw, setrounding_raw

import .Base.GMP: ClongMax, CulongMax, CdoubleMax, Limb

import .Base.FastMath.sincos_fast

version() = VersionNumber(unsafe_string(ccall((:mpfr_get_version,:libmpfr), Ptr{Cchar}, ())))
patches() = split(unsafe_string(ccall((:mpfr_get_patches,:libmpfr), Ptr{Cchar}, ())),' ')

function __init__()
    try
        # set exponent to full range by default
        set_emin!(get_emin_min())
        set_emax!(get_emax_max())
    catch ex
        Base.showerror_nostdio(ex, "WARNING: Error during initialization of module MPFR")
    end
    nothing
end

# Matches the MPFR_RNDN, etc.
# https://www.mpfr.org/mpfr-current/mpfr.html#Rounding-Modes
@enum MPFRRoundingMode begin
    MPFRRoundNearest
    MPFRRoundToZero
    MPFRRoundUp
    MPFRRoundDown
    MPFRRoundFromZero
end

convert(::Type{MPFRRoundingMode}, ::RoundingMode{:Nearest})  = MPFRRoundNearest
convert(::Type{MPFRRoundingMode}, ::RoundingMode{:ToZero})   = MPFRRoundToZero
convert(::Type{MPFRRoundingMode}, ::RoundingMode{:Up})       = MPFRRoundUp
convert(::Type{MPFRRoundingMode}, ::RoundingMode{:Down})     = MPFRRoundDown
convert(::Type{MPFRRoundingMode}, ::RoundingMode{:FromZero}) = MPFRRoundFromZero

function convert(::Type{RoundingMode}, r::MPFRRoundingMode)
    if r == MPFRRoundNearest
        return RoundNearest
    elseif r == MPFRRoundToZero
        return RoundToZero
    elseif r == MPFRRoundUp
        return RoundUp
    elseif r == MPFRRoundDown
        return RoundDown
    elseif r == MPFRRoundFromZero
        return RoundFromZero
    else
        throw(ArgumentError("invalid MPFR rounding mode code: $c"))
    end
end

const ROUNDING_MODE = Ref{MPFRRoundingMode}(MPFRRoundNearest)
const DEFAULT_PRECISION = Ref{Clong}(256)

# Basic type and initialization definitions

"""
    BigFloat <: AbstractFloat

Arbitrary precision floating point number type.
"""
mutable struct BigFloat <: AbstractFloat
    prec::Clong
    sign::Cint
    exp::Clong
    d::Ptr{Limb}
    # _d::Buffer{Limb} # Julia gc handle for memory @ d
    _d::String # Julia gc handle for memory @ d (optimized)

    # Not recommended for general use:
    # used internally by, e.g. deepcopy
    global function _BigFloat(prec::Clong, sign::Cint, exp::Clong, d::String)
        # ccall-based version, inlined below
        #z = new(zero(Clong), zero(Cint), zero(Clong), C_NULL, d)
        #ccall((:mpfr_custom_init,:libmpfr), Cvoid, (Ptr{Limb}, Clong), d, prec) # currently seems to be a no-op in mpfr
        #NAN_KIND = Cint(0)
        #ccall((:mpfr_custom_init_set,:libmpfr), Cvoid, (Ref{BigFloat}, Cint, Clong, Ptr{Limb}), z, NAN_KIND, prec, d)
        #return z
        return new(prec, sign, exp, pointer(d), d)
    end

    function BigFloat(; precision::Integer=precision(BigFloat))
        nb = ccall((:mpfr_custom_get_size,:libmpfr), Csize_t, (Clong,), precision)
        nb = (nb + Core.sizeof(Limb) - 1) ÷ Core.sizeof(Limb) # align to number of Limb allocations required for this
        #d = Vector{Limb}(undef, nb)
        d = _string_n(nb * Core.sizeof(Limb))
        EXP_NAN = Clong(1) - Clong(typemax(Culong) >> 1)
        return _BigFloat(Clong(precision), one(Cint), EXP_NAN, d) # +NAN
    end
end

rounding_raw(::Type{BigFloat}) = ROUNDING_MODE[]
setrounding_raw(::Type{BigFloat}, r::MPFRRoundingMode) = ROUNDING_MODE[]=r

rounding(::Type{BigFloat}) = convert(RoundingMode, rounding_raw(BigFloat))
setrounding(::Type{BigFloat},r::RoundingMode) = setrounding_raw(BigFloat, convert(MPFRRoundingMode, r))


# overload the definition of unsafe_convert to ensure that `x.d` is assigned
# it may have been dropped in the event that the BigFloat was serialized
Base.unsafe_convert(::Type{Ref{BigFloat}}, x::Ptr{BigFloat}) = x
@inline function Base.unsafe_convert(::Type{Ref{BigFloat}}, x::Ref{BigFloat})
    x = x[]
    if x.d == C_NULL
        x.d = pointer(x._d)
    end
    return convert(Ptr{BigFloat}, Base.pointer_from_objref(x))
end

"""
    BigFloat(x::Union{Real, AbstractString} [, rounding::RoundingMode=rounding(BigFloat)]; [precision::Integer=precision(BigFloat)])

Create an arbitrary precision floating point number from `x`, with precision
`precision`. The `rounding` argument specifies the direction in which the result should be
rounded if the conversion cannot be done exactly. If not provided, these are set by the current global values.

`BigFloat(x::Real)` is the same as `convert(BigFloat,x)`, except if `x` itself is already
`BigFloat`, in which case it will return a value with the precision set to the current
global precision; `convert` will always return `x`.

`BigFloat(x::AbstractString)` is identical to [`parse`](@ref), but is provided for
convenience since decimal literals are converted to floating point numbers when parsed.
`BigFloat(2.1)` may not yield what you expect.

```jldoctest
julia> BigFloat(2.1) # 2.1 here is a Float64
2.100000000000000088817841970012523233890533447265625

julia> BigFloat("2.1") # the closest BigFloat to 2.1
2.099999999999999999999999999999999999999999999999999999999999999999999999999986

julia> BigFloat("2.1", RoundUp)
2.100000000000000000000000000000000000000000000000000000000000000000000000000021

julia> BigFloat("2.1", RoundUp, precision=128)
2.100000000000000000000000000000000000007
```

# See also
- [`@big_str`](@ref)
- [`rounding`](@ref) and [`setrounding`](@ref)
- [`precision`](@ref) and [`setprecision`](@ref)
"""
BigFloat(x, r::RoundingMode)

widen(::Type{Float64}) = BigFloat
widen(::Type{BigFloat}) = BigFloat

function BigFloat(x::BigFloat, r::MPFRRoundingMode=ROUNDING_MODE[]; precision::Integer=precision(BigFloat))
    if precision == MPFR.precision(x)
        x
    else
        z = BigFloat(;precision=precision)
        ccall((:mpfr_set, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode),
              z, x, r)
        z
    end
end


# convert to BigFloat
for (fJ, fC) in ((:si,:Clong), (:ui,:Culong))
    @eval begin
        function BigFloat(x::($fC), r::MPFRRoundingMode=ROUNDING_MODE[]; precision::Integer=precision(BigFloat))
            z = BigFloat(;precision=precision)
            ccall(($(string(:mpfr_set_,fJ)), :libmpfr), Int32, (Ref{BigFloat}, $fC, MPFRRoundingMode), z, x, r)
            return z
        end
    end
end

function BigFloat(x::Float64, r::MPFRRoundingMode=ROUNDING_MODE[]; precision::Integer=precision(BigFloat))
    z = BigFloat(;precision=precision)
    ccall((:mpfr_set_d, :libmpfr), Int32, (Ref{BigFloat}, Float64, MPFRRoundingMode), z, x, r)
    if isnan(x) && signbit(x) != signbit(z)
        z.sign = -z.sign
    end
    return z
end

function BigFloat(x::BigInt, r::MPFRRoundingMode=ROUNDING_MODE[]; precision::Integer=precision(BigFloat))
    z = BigFloat(;precision=precision)
    ccall((:mpfr_set_z, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigInt}, MPFRRoundingMode), z, x, r)
    return z
end

BigFloat(x::Integer, r::MPFRRoundingMode=ROUNDING_MODE[]; precision::Integer=precision(BigFloat)) =
    BigFloat(BigInt(x), r; precision=precision)

BigFloat(x::Union{Bool,Int8,Int16,Int32}, r::MPFRRoundingMode=ROUNDING_MODE[]; precision::Integer=precision(BigFloat)) =
    BigFloat(convert(Clong, x), r; precision=precision)
BigFloat(x::Union{UInt8,UInt16,UInt32}, r::MPFRRoundingMode=ROUNDING_MODE[]; precision::Integer=precision(BigFloat)) =
    BigFloat(convert(Culong, x), r; precision=precision)

BigFloat(x::Union{Float16,Float32}, r::MPFRRoundingMode=ROUNDING_MODE[]; precision::Integer=precision(BigFloat)) =
    BigFloat(Float64(x), r; precision=precision)

BigFloat(x::Rational, r::MPFRRoundingMode=ROUNDING_MODE[]; precision::Integer=precision(BigFloat)) =
    BigFloat(numerator(x), r ;precision=precision) / BigFloat(denominator(x), r ;precision=precision)

function tryparse(::Type{BigFloat}, s::AbstractString; base::Integer=0, precision::Integer=precision(BigFloat), rounding::MPFRRoundingMode=ROUNDING_MODE[])
    !isempty(s) && isspace(s[end]) && return tryparse(BigFloat, rstrip(s), base = base)
    z = BigFloat(precision=precision)
    err = ccall((:mpfr_set_str, :libmpfr), Int32, (Ref{BigFloat}, Cstring, Int32, MPFRRoundingMode), z, s, base, rounding)
    err == 0 ? z : nothing
end

BigFloat(x::AbstractString, r::MPFRRoundingMode=ROUNDING_MODE[]; precision=precision(BigFloat)) =
    parse(BigFloat, x; precision=precision, rounding=r)

Rational(x::BigFloat) = convert(Rational{BigInt}, x)
AbstractFloat(x::BigInt) = BigFloat(x)

float(::Type{BigInt}) = BigFloat

BigFloat(x::Real, r::RoundingMode; precision::Integer=precision(BigFloat)) =
    BigFloat(x, convert(MPFRRoundingMode, r); precision=precision)
BigFloat(x::AbstractString, r::RoundingMode; precision::Integer=precision(BigFloat)) =
    BigFloat(x, convert(MPFRRoundingMode, r); precision=precision)

# TODO: deprecate in 2.0
BigFloat(x, prec::Int) = BigFloat(x; precision=prec)
BigFloat(x, prec::Int, rounding::RoundingMode) = BigFloat(x, rounding; precision=prec)
# avoid ambiguity

BigFloat(x::Real, prec::Int) = BigFloat(x; precision=prec)
BigFloat(x::Real, prec::Int, rounding::RoundingMode) = BigFloat(x, rounding; precision=prec)

## BigFloat -> Integer
unsafe_cast(T, x::BigFloat, r::RoundingMode) = unsafe_cast(T, x, convert(MPFRRoundingMode, r))

function unsafe_cast(::Type{Int64}, x::BigFloat, r::MPFRRoundingMode)
    ccall((:__gmpfr_mpfr_get_sj,:libmpfr), Cintmax_t, (Ref{BigFloat}, MPFRRoundingMode), x, r)
end
function unsafe_cast(::Type{UInt64}, x::BigFloat, r::MPFRRoundingMode)
    ccall((:__gmpfr_mpfr_get_uj,:libmpfr), Cuintmax_t, (Ref{BigFloat}, MPFRRoundingMode), x, r)
end

function unsafe_cast(::Type{T}, x::BigFloat, r::MPFRRoundingMode) where T<:Signed
    unsafe_cast(Int64, x, r) % T
end
function unsafe_cast(::Type{T}, x::BigFloat, r::MPFRRoundingMode) where T<:Unsigned
    unsafe_cast(UInt64, x, r) % T
end

function unsafe_cast(::Type{BigInt}, x::BigFloat, r::MPFRRoundingMode)
    # actually safe, just keep naming consistent
    z = BigInt()
    ccall((:mpfr_get_z, :libmpfr), Int32, (Ref{BigInt}, Ref{BigFloat}, MPFRRoundingMode), z, x, r)
    return z
end
unsafe_cast(::Type{Int128}, x::BigFloat, r::MPFRRoundingMode) = Int128(unsafe_cast(BigInt, x, r))
unsafe_cast(::Type{UInt128}, x::BigFloat, r::MPFRRoundingMode) = UInt128(unsafe_cast(BigInt, x, r))
unsafe_cast(::Type{T}, x::BigFloat, r::MPFRRoundingMode) where {T<:Integer} = unsafe_cast(T, x, r)

unsafe_trunc(::Type{T}, x::BigFloat) where {T<:Integer} = unsafe_cast(T, x, RoundToZero)

function trunc(::Type{T}, x::BigFloat) where T<:Union{Signed,Unsigned}
    (typemin(T) <= x <= typemax(T)) || throw(InexactError(:trunc, T, x))
    unsafe_cast(T, x, RoundToZero)
end
function floor(::Type{T}, x::BigFloat) where T<:Union{Signed,Unsigned}
    (typemin(T) <= x <= typemax(T)) || throw(InexactError(:floor, T, x))
    unsafe_cast(T, x, RoundDown)
end
function ceil(::Type{T}, x::BigFloat) where T<:Union{Signed,Unsigned}
    (typemin(T) <= x <= typemax(T)) || throw(InexactError(:ceil, T, x))
    unsafe_cast(T, x, RoundUp)
end

function round(::Type{T}, x::BigFloat) where T<:Union{Signed,Unsigned}
    (typemin(T) <= x <= typemax(T)) || throw(InexactError(:round, T, x))
    unsafe_cast(T, x, ROUNDING_MODE[])
end

trunc(::Type{BigInt}, x::BigFloat) = unsafe_cast(BigInt, x, RoundToZero)
floor(::Type{BigInt}, x::BigFloat) = unsafe_cast(BigInt, x, RoundDown)
ceil(::Type{BigInt}, x::BigFloat) = unsafe_cast(BigInt, x, RoundUp)
round(::Type{BigInt}, x::BigFloat) = unsafe_cast(BigInt, x, ROUNDING_MODE[])

# convert/round/trunc/floor/ceil(Integer, x) should return a BigInt
trunc(::Type{Integer}, x::BigFloat) = trunc(BigInt, x)
floor(::Type{Integer}, x::BigFloat) = floor(BigInt, x)
ceil(::Type{Integer}, x::BigFloat) = ceil(BigInt, x)
round(::Type{Integer}, x::BigFloat) = round(BigInt, x)

function Bool(x::BigFloat)
    iszero(x) && return false
    isone(x) && return true
    throw(InexactError(:Bool, Bool, x))
end
function BigInt(x::BigFloat)
    isinteger(x) || throw(InexactError(:BigInt, BigInt, x))
    trunc(BigInt, x)
end

function (::Type{T})(x::BigFloat) where T<:Integer
    isinteger(x) || throw(InexactError(Symbol(string(T)), T, x))
    trunc(T,x)
end

## BigFloat -> AbstractFloat

_cpynansgn(x::AbstractFloat, y::BigFloat) = isnan(x) && signbit(x) != signbit(y) ? -x : x

Float64(x::BigFloat) =
    _cpynansgn(ccall((:mpfr_get_d,:libmpfr), Float64, (Ref{BigFloat}, MPFRRoundingMode), x, ROUNDING_MODE[]), x)
Float32(x::BigFloat) =
    _cpynansgn(ccall((:mpfr_get_flt,:libmpfr), Float32, (Ref{BigFloat}, MPFRRoundingMode), x, ROUNDING_MODE[]), x)
# TODO: avoid double rounding
Float16(x::BigFloat) = Float16(Float32(x))

Float64(x::BigFloat, r::MPFRRoundingMode) =
    _cpynansgn(ccall((:mpfr_get_d,:libmpfr), Float64, (Ref{BigFloat}, MPFRRoundingMode), x, r), x)
Float32(x::BigFloat, r::MPFRRoundingMode) =
    _cpynansgn(ccall((:mpfr_get_flt,:libmpfr), Float32, (Ref{BigFloat}, MPFRRoundingMode), x, r), x)
# TODO: avoid double rounding
Float16(x::BigFloat, r::RoundingMode) = Float16(Float32(x, r))

promote_rule(::Type{BigFloat}, ::Type{<:Real}) = BigFloat
promote_rule(::Type{BigInt}, ::Type{<:AbstractFloat}) = BigFloat
promote_rule(::Type{BigFloat}, ::Type{<:AbstractFloat}) = BigFloat

big(::Type{<:AbstractFloat}) = BigFloat

function (::Type{Rational{BigInt}})(x::AbstractFloat)
    isnan(x) && return zero(BigInt) // zero(BigInt)
    isinf(x) && return copysign(one(BigInt),x) // zero(BigInt)
    iszero(x) && return zero(BigInt) // one(BigInt)
    s = max(precision(x) - exponent(x), 0)
    BigInt(ldexp(x,s)) // (BigInt(1) << s)
end

# Basic arithmetic without promotion
for (fJ, fC) in ((:+,:add), (:*,:mul))
    @eval begin
        # BigFloat
        function ($fJ)(x::BigFloat, y::BigFloat)
            z = BigFloat()
            ccall(($(string(:mpfr_,fC)),:libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, x, y, ROUNDING_MODE[])
            return z
        end

        # Unsigned Integer
        function ($fJ)(x::BigFloat, c::CulongMax)
            z = BigFloat()
            ccall(($(string(:mpfr_,fC,:_ui)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Culong, MPFRRoundingMode), z, x, c, ROUNDING_MODE[])
            return z
        end
        ($fJ)(c::CulongMax, x::BigFloat) = ($fJ)(x,c)

        # Signed Integer
        function ($fJ)(x::BigFloat, c::ClongMax)
            z = BigFloat()
            ccall(($(string(:mpfr_,fC,:_si)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Clong, MPFRRoundingMode), z, x, c, ROUNDING_MODE[])
            return z
        end
        ($fJ)(c::ClongMax, x::BigFloat) = ($fJ)(x,c)

        # Float32/Float64
        function ($fJ)(x::BigFloat, c::CdoubleMax)
            z = BigFloat()
            ccall(($(string(:mpfr_,fC,:_d)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Cdouble, MPFRRoundingMode), z, x, c, ROUNDING_MODE[])
            return z
        end
        ($fJ)(c::CdoubleMax, x::BigFloat) = ($fJ)(x,c)

        # BigInt
        function ($fJ)(x::BigFloat, c::BigInt)
            z = BigFloat()
            ccall(($(string(:mpfr_,fC,:_z)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigInt}, MPFRRoundingMode), z, x, c, ROUNDING_MODE[])
            return z
        end
        ($fJ)(c::BigInt, x::BigFloat) = ($fJ)(x,c)
    end
end

for (fJ, fC) in ((:-,:sub), (:/,:div))
    @eval begin
        # BigFloat
        function ($fJ)(x::BigFloat, y::BigFloat)
            z = BigFloat()
            ccall(($(string(:mpfr_,fC)),:libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, x, y, ROUNDING_MODE[])
            return z
        end

        # Unsigned Int
        function ($fJ)(x::BigFloat, c::CulongMax)
            z = BigFloat()
            ccall(($(string(:mpfr_,fC,:_ui)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Culong, MPFRRoundingMode), z, x, c, ROUNDING_MODE[])
            return z
        end
        function ($fJ)(c::CulongMax, x::BigFloat)
            z = BigFloat()
            ccall(($(string(:mpfr_,:ui_,fC)), :libmpfr), Int32, (Ref{BigFloat}, Culong, Ref{BigFloat}, MPFRRoundingMode), z, c, x, ROUNDING_MODE[])
            return z
        end

        # Signed Integer
        function ($fJ)(x::BigFloat, c::ClongMax)
            z = BigFloat()
            ccall(($(string(:mpfr_,fC,:_si)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Clong, MPFRRoundingMode), z, x, c, ROUNDING_MODE[])
            return z
        end
        function ($fJ)(c::ClongMax, x::BigFloat)
            z = BigFloat()
            ccall(($(string(:mpfr_,:si_,fC)), :libmpfr), Int32, (Ref{BigFloat}, Clong, Ref{BigFloat}, MPFRRoundingMode), z, c, x, ROUNDING_MODE[])
            return z
        end

        # Float32/Float64
        function ($fJ)(x::BigFloat, c::CdoubleMax)
            z = BigFloat()
            ccall(($(string(:mpfr_,fC,:_d)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Cdouble, MPFRRoundingMode), z, x, c, ROUNDING_MODE[])
            return z
        end
        function ($fJ)(c::CdoubleMax, x::BigFloat)
            z = BigFloat()
            ccall(($(string(:mpfr_,:d_,fC)), :libmpfr), Int32, (Ref{BigFloat}, Cdouble, Ref{BigFloat}, MPFRRoundingMode), z, c, x, ROUNDING_MODE[])
            return z
        end

        # BigInt
        function ($fJ)(x::BigFloat, c::BigInt)
            z = BigFloat()
            ccall(($(string(:mpfr_,fC,:_z)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigInt}, MPFRRoundingMode), z, x, c, ROUNDING_MODE[])
            return z
        end
        # no :mpfr_z_div function
    end
end

function -(c::BigInt, x::BigFloat)
    z = BigFloat()
    ccall((:mpfr_z_sub, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigInt}, Ref{BigFloat}, MPFRRoundingMode), z, c, x, ROUNDING_MODE[])
    return z
end

inv(x::BigFloat) = one(Clong) / x # faster than fallback one(x)/x

function fma(x::BigFloat, y::BigFloat, z::BigFloat)
    r = BigFloat()
    ccall(("mpfr_fma",:libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), r, x, y, z, ROUNDING_MODE[])
    return r
end

# div
# BigFloat
function div(x::BigFloat, y::BigFloat)
    z = BigFloat()
    ccall((:mpfr_div,:libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, x, y, RoundToZero)
    ccall((:mpfr_trunc, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}), z, z)
    return z
end

# Unsigned Int
function div(x::BigFloat, c::CulongMax)
    z = BigFloat()
    ccall((:mpfr_div_ui, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Culong, MPFRRoundingMode), z, x, c, RoundToZero)
    ccall((:mpfr_trunc, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}), z, z)
    return z
end
function div(c::CulongMax, x::BigFloat)
    z = BigFloat()
    ccall((:mpfr_ui_div, :libmpfr), Int32, (Ref{BigFloat}, Culong, Ref{BigFloat}, MPFRRoundingMode), z, c, x, RoundToZero)
    ccall((:mpfr_trunc, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}), z, z)
    return z
end

# Signed Integer
function div(x::BigFloat, c::ClongMax)
    z = BigFloat()
    ccall((:mpfr_div_si, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Clong, MPFRRoundingMode), z, x, c, RoundToZero)
    ccall((:mpfr_trunc, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}), z, z)
    return z
end
function div(c::ClongMax, x::BigFloat)
    z = BigFloat()
    ccall((:mpfr_si_div, :libmpfr), Int32, (Ref{BigFloat}, Clong, Ref{BigFloat}, MPFRRoundingMode), z, c, x, RoundToZero)
    ccall((:mpfr_trunc, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}), z, z)
    return z
end

# Float32/Float64
function div(x::BigFloat, c::CdoubleMax)
    z = BigFloat()
    ccall((:mpfr_div_d, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Cdouble, MPFRRoundingMode), z, x, c, RoundToZero)
    ccall((:mpfr_trunc, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}), z, z)
    return z
end
function div(c::CdoubleMax, x::BigFloat)
    z = BigFloat()
    ccall((:mpfr_d_div, :libmpfr), Int32, (Ref{BigFloat}, Cdouble, Ref{BigFloat}, MPFRRoundingMode), z, c, x, RoundToZero)
    ccall((:mpfr_trunc, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}), z, z)
    return z
end

# BigInt
function div(x::BigFloat, c::BigInt)
    z = BigFloat()
    ccall((:mpfr_div_z, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigInt}, MPFRRoundingMode), z, x, c, RoundToZero)
    ccall((:mpfr_trunc, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}), z, z)
    return z
end


# More efficient commutative operations
for (fJ, fC, fI) in ((:+, :add, 0), (:*, :mul, 1))
    @eval begin
        function ($fJ)(a::BigFloat, b::BigFloat, c::BigFloat)
            z = BigFloat()
            ccall(($(string(:mpfr_,fC)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, a, b, ROUNDING_MODE[])
            ccall(($(string(:mpfr_,fC)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, z, c, ROUNDING_MODE[])
            return z
        end
        function ($fJ)(a::BigFloat, b::BigFloat, c::BigFloat, d::BigFloat)
            z = BigFloat()
            ccall(($(string(:mpfr_,fC)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, a, b, ROUNDING_MODE[])
            ccall(($(string(:mpfr_,fC)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, z, c, ROUNDING_MODE[])
            ccall(($(string(:mpfr_,fC)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, z, d, ROUNDING_MODE[])
            return z
        end
        function ($fJ)(a::BigFloat, b::BigFloat, c::BigFloat, d::BigFloat, e::BigFloat)
            z = BigFloat()
            ccall(($(string(:mpfr_,fC)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, a, b, ROUNDING_MODE[])
            ccall(($(string(:mpfr_,fC)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, z, c, ROUNDING_MODE[])
            ccall(($(string(:mpfr_,fC)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, z, d, ROUNDING_MODE[])
            ccall(($(string(:mpfr_,fC)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, z, e, ROUNDING_MODE[])
            return z
        end
    end
end

function -(x::BigFloat)
    z = BigFloat()
    ccall((:mpfr_neg, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, x, ROUNDING_MODE[])
    return z
end

function sqrt(x::BigFloat)
    isnan(x) && return x
    z = BigFloat()
    ccall((:mpfr_sqrt, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, x, ROUNDING_MODE[])
    isnan(z) && throw(DomainError(x, "NaN result for non-NaN input."))
    return z
end

sqrt(x::BigInt) = sqrt(BigFloat(x))

function ^(x::BigFloat, y::BigFloat)
    z = BigFloat()
    ccall((:mpfr_pow, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, x, y, ROUNDING_MODE[])
    return z
end

function ^(x::BigFloat, y::CulongMax)
    z = BigFloat()
    ccall((:mpfr_pow_ui, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Culong, MPFRRoundingMode), z, x, y, ROUNDING_MODE[])
    return z
end

function ^(x::BigFloat, y::ClongMax)
    z = BigFloat()
    ccall((:mpfr_pow_si, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Clong, MPFRRoundingMode), z, x, y, ROUNDING_MODE[])
    return z
end

function ^(x::BigFloat, y::BigInt)
    z = BigFloat()
    ccall((:mpfr_pow_z, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigInt}, MPFRRoundingMode), z, x, y, ROUNDING_MODE[])
    return z
end

^(x::BigFloat, y::Integer)  = typemin(Clong)  <= y <= typemax(Clong)  ? x^Clong(y)  : x^BigInt(y)
^(x::BigFloat, y::Unsigned) = typemin(Culong) <= y <= typemax(Culong) ? x^Culong(y) : x^BigInt(y)

for f in (:exp, :exp2, :exp10, :expm1, :cosh, :sinh, :tanh, :sech, :csch, :coth, :cbrt)
    @eval function $f(x::BigFloat)
        z = BigFloat()
        ccall(($(string(:mpfr_,f)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, x, ROUNDING_MODE[])
        return z
    end
end

function sincos_fast(v::BigFloat)
    s = BigFloat()
    c = BigFloat()
    ccall((:mpfr_sin_cos, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), s, c, v, ROUNDING_MODE[])
    return (s, c)
end
sincos(v::BigFloat) = sincos_fast(v)

# return log(2)
function big_ln2()
    c = BigFloat()
    ccall((:mpfr_const_log2, :libmpfr), Cint, (Ref{BigFloat}, MPFRRoundingMode), c, MPFR.ROUNDING_MODE[])
    return c
end

function ldexp(x::BigFloat, n::Clong)
    z = BigFloat()
    ccall((:mpfr_mul_2si, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Clong, MPFRRoundingMode), z, x, n, ROUNDING_MODE[])
    return z
end
function ldexp(x::BigFloat, n::Culong)
    z = BigFloat()
    ccall((:mpfr_mul_2ui, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Culong, MPFRRoundingMode), z, x, n, ROUNDING_MODE[])
    return z
end
ldexp(x::BigFloat, n::ClongMax) = ldexp(x, convert(Clong, n))
ldexp(x::BigFloat, n::CulongMax) = ldexp(x, convert(Culong, n))
ldexp(x::BigFloat, n::Integer) = x * exp2(BigFloat(n))

function factorial(x::BigFloat)
    if x < 0 || !isinteger(x)
        throw(DomainError(x, "Must be a non-negative integer."))
    end
    ui = convert(Culong, x)
    z = BigFloat()
    ccall((:mpfr_fac_ui, :libmpfr), Int32, (Ref{BigFloat}, Culong, MPFRRoundingMode), z, ui, ROUNDING_MODE[])
    return z
end

function hypot(x::BigFloat, y::BigFloat)
    z = BigFloat()
    ccall((:mpfr_hypot, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, x, y, ROUNDING_MODE[])
    return z
end

for f in (:log, :log2, :log10)
    @eval function $f(x::BigFloat)
        if x < 0
            throw(DomainError(x, string($f, " will only return a complex result if called ",
                              "with a complex argument. Try ", $f, "(complex(x)).")))
        end
        z = BigFloat()
        ccall(($(string(:mpfr_,f)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, x, ROUNDING_MODE[])
        return z
    end
end

function log1p(x::BigFloat)
    if x < -1
        throw(DomainError(x, string("log1p will only return a complex result if called ",
                          "with a complex argument. Try log1p(complex(x)).")))
    end
    z = BigFloat()
    ccall((:mpfr_log1p, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, x, ROUNDING_MODE[])
    return z
end

function max(x::BigFloat, y::BigFloat)
    isnan(x) && return x
    isnan(y) && return y
    z = BigFloat()
    ccall((:mpfr_max, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, x, y, ROUNDING_MODE[])
    return z
end

function min(x::BigFloat, y::BigFloat)
    isnan(x) && return x
    isnan(y) && return y
    z = BigFloat()
    ccall((:mpfr_min, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, x, y, ROUNDING_MODE[])
    return z
end

function modf(x::BigFloat)
    isinf(x) && return (BigFloat(NaN), x)
    zint = BigFloat()
    zfloat = BigFloat()
    ccall((:mpfr_modf, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), zint, zfloat, x, ROUNDING_MODE[])
    return (zfloat, zint)
end

function rem(x::BigFloat, y::BigFloat)
    z = BigFloat()
    ccall((:mpfr_fmod, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, x, y, ROUNDING_MODE[])
    return z
end

function rem(x::BigFloat, y::BigFloat, ::RoundingMode{:Nearest})
    z = BigFloat()
    ccall((:mpfr_remainder, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, x, y, ROUNDING_MODE[])
    return z
end

# TODO: use a higher-precision BigFloat(pi) here?
rem2pi(x::BigFloat, r::RoundingMode) = rem(x, 2*BigFloat(pi), r)

function sum(arr::AbstractArray{BigFloat})
    z = BigFloat(0)
    for i in arr
        ccall((:mpfr_add, :libmpfr), Int32,
            (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, z, i, ROUNDING_MODE[])
    end
    return z
end

# Functions for which NaN results are converted to DomainError, following Base
for f in (:sin, :cos, :tan, :sec, :csc, :acos, :asin, :atan, :acosh, :asinh, :atanh)
    @eval begin
        function ($f)(x::BigFloat)
            isnan(x) && return x
            z = BigFloat()
            ccall(($(string(:mpfr_,f)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, x, ROUNDING_MODE[])
            isnan(z) && throw(DomainError(x, "NaN result for non-NaN input."))
            return z
        end
    end
end

function atan(y::BigFloat, x::BigFloat)
    z = BigFloat()
    ccall((:mpfr_atan2, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, y, x, ROUNDING_MODE[])
    return z
end

# Utility functions
==(x::BigFloat, y::BigFloat) = ccall((:mpfr_equal_p, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}), x, y) != 0
<=(x::BigFloat, y::BigFloat) = ccall((:mpfr_lessequal_p, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}), x, y) != 0
>=(x::BigFloat, y::BigFloat) = ccall((:mpfr_greaterequal_p, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}), x, y) != 0
<(x::BigFloat, y::BigFloat) = ccall((:mpfr_less_p, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}), x, y) != 0
>(x::BigFloat, y::BigFloat) = ccall((:mpfr_greater_p, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}), x, y) != 0

function cmp(x::BigFloat, y::BigInt)
    isnan(x) && return 1
    ccall((:mpfr_cmp_z, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigInt}), x, y)
end
function cmp(x::BigFloat, y::ClongMax)
    isnan(x) && return 1
    ccall((:mpfr_cmp_si, :libmpfr), Int32, (Ref{BigFloat}, Clong), x, y)
end
function cmp(x::BigFloat, y::CulongMax)
    isnan(x) && return 1
    ccall((:mpfr_cmp_ui, :libmpfr), Int32, (Ref{BigFloat}, Culong), x, y)
end
cmp(x::BigFloat, y::Integer) = cmp(x,big(y))
cmp(x::Integer, y::BigFloat) = -cmp(y,x)

function cmp(x::BigFloat, y::CdoubleMax)
    isnan(x) && return isnan(y) ? 0 : 1
    isnan(y) && return -1
    ccall((:mpfr_cmp_d, :libmpfr), Int32, (Ref{BigFloat}, Cdouble), x, y)
end
cmp(x::CdoubleMax, y::BigFloat) = -cmp(y,x)

==(x::BigFloat, y::Integer)    = !isnan(x) && cmp(x,y) == 0
==(x::Integer, y::BigFloat)    = y == x
==(x::BigFloat, y::CdoubleMax) = !isnan(x) && !isnan(y) && cmp(x,y) == 0
==(x::CdoubleMax, y::BigFloat) = y == x

<(x::BigFloat, y::Integer)    = !isnan(x) && cmp(x,y) < 0
<(x::Integer, y::BigFloat)    = !isnan(y) && cmp(y,x) > 0
<(x::BigFloat, y::CdoubleMax) = !isnan(x) && !isnan(y) && cmp(x,y) < 0
<(x::CdoubleMax, y::BigFloat) = !isnan(x) && !isnan(y) && cmp(y,x) > 0

<=(x::BigFloat, y::Integer)    = !isnan(x) && cmp(x,y) <= 0
<=(x::Integer, y::BigFloat)    = !isnan(y) && cmp(y,x) >= 0
<=(x::BigFloat, y::CdoubleMax) = !isnan(x) && !isnan(y) && cmp(x,y) <= 0
<=(x::CdoubleMax, y::BigFloat) = !isnan(x) && !isnan(y) && cmp(y,x) >= 0

signbit(x::BigFloat) = ccall((:mpfr_signbit, :libmpfr), Int32, (Ref{BigFloat},), x) != 0

function precision(x::BigFloat)  # precision of an object of type BigFloat
    return ccall((:mpfr_get_prec, :libmpfr), Clong, (Ref{BigFloat},), x)
end

"""
    precision(BigFloat)

Get the precision (in bits) currently used for [`BigFloat`](@ref) arithmetic.
"""
precision(::Type{BigFloat}) = DEFAULT_PRECISION[] # precision of the type BigFloat itself

"""
    setprecision([T=BigFloat,] precision::Int)

Set the precision (in bits) to be used for `T` arithmetic.
"""
function setprecision(::Type{BigFloat}, precision::Integer)
    if precision < 2
        throw(DomainError(precision, "`precision` cannot be less than 2."))
    end
    DEFAULT_PRECISION[] = precision
    return precision
end

setprecision(precision::Integer) = setprecision(BigFloat, precision)

maxintfloat(x::BigFloat) = BigFloat(2)^precision(x)
maxintfloat(::Type{BigFloat}) = BigFloat(2)^precision(BigFloat)

function copysign(x::BigFloat, y::BigFloat)
    z = BigFloat()
    ccall((:mpfr_copysign, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), z, x, y, ROUNDING_MODE[])
    return z
end

function exponent(x::BigFloat)
    if iszero(x) || !isfinite(x)
        throw(DomainError(x, "`x` must be non-zero and finite."))
    end
    # The '- 1' is to make it work as Base.exponent
    return ccall((:mpfr_get_exp, :libmpfr), Clong, (Ref{BigFloat},), x) - 1
end

function frexp(x::BigFloat)
    z = BigFloat()
    c = Ref{Clong}()
    ccall((:mpfr_frexp, :libmpfr), Int32, (Ptr{Clong}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), c, z, x, ROUNDING_MODE[])
    return (z, c[])
end

function significand(x::BigFloat)
    z = BigFloat()
    c = Ref{Clong}()
    ccall((:mpfr_frexp, :libmpfr), Int32, (Ptr{Clong}, Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode), c, z, x, ROUNDING_MODE[])
    # Double the significand to make it work as Base.significand
    ccall((:mpfr_mul_si, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Clong, MPFRRoundingMode), z, z, 2, ROUNDING_MODE[])
    return z
end

function isinteger(x::BigFloat)
    return ccall((:mpfr_integer_p, :libmpfr), Int32, (Ref{BigFloat},), x) != 0
end

for (f,R) in ((:roundeven, :Nearest),
              (:ceil, :Up),
              (:floor, :Down),
              (:trunc, :ToZero),
              (:round, :NearestTiesAway))
    @eval begin
        function round(x::BigFloat, ::RoundingMode{$(QuoteNode(R))})
            z = BigFloat()
            ccall(($(string(:mpfr_,f)), :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}), z, x)
            return z
        end
    end
end

function isinf(x::BigFloat)
    return ccall((:mpfr_inf_p, :libmpfr), Int32, (Ref{BigFloat},), x) != 0
end

function isnan(x::BigFloat)
    return ccall((:mpfr_nan_p, :libmpfr), Int32, (Ref{BigFloat},), x) != 0
end

isfinite(x::BigFloat) = !isinf(x) && !isnan(x)

iszero(x::BigFloat) = x == Clong(0)
isone(x::BigFloat) = x == Clong(1)

@eval typemax(::Type{BigFloat}) = $(BigFloat(Inf))
@eval typemin(::Type{BigFloat}) = $(BigFloat(-Inf))

function nextfloat(x::BigFloat)
    z = BigFloat()
    ccall((:mpfr_set, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode),
          z, x, ROUNDING_MODE[])
    ccall((:mpfr_nextabove, :libmpfr), Int32, (Ref{BigFloat},), z) != 0
    return z
end

function prevfloat(x::BigFloat)
    z = BigFloat()
    ccall((:mpfr_set, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, MPFRRoundingMode),
          z, x, ROUNDING_MODE[])
    ccall((:mpfr_nextbelow, :libmpfr), Int32, (Ref{BigFloat},), z) != 0
    return z
end

eps(::Type{BigFloat}) = nextfloat(BigFloat(1)) - BigFloat(1)

floatmin(::Type{BigFloat}) = nextfloat(zero(BigFloat))
floatmax(::Type{BigFloat}) = prevfloat(BigFloat(Inf))

"""
    setprecision(f::Function, [T=BigFloat,] precision::Integer)

Change the `T` arithmetic precision (in bits) for the duration of `f`.
It is logically equivalent to:

    old = precision(BigFloat)
    setprecision(BigFloat, precision)
    f()
    setprecision(BigFloat, old)

Often used as `setprecision(T, precision) do ... end`
"""
function setprecision(f::Function, ::Type{T}, prec::Integer) where T
    old_prec = precision(T)
    setprecision(T, prec)
    try
        return f()
    finally
        setprecision(T, old_prec)
    end
end

setprecision(f::Function, prec::Integer) = setprecision(f, BigFloat, prec)

function string_mpfr(x::BigFloat, fmt::String)
    buf = Base.StringVector(0)
    s = _calculate_buffer_size!(buf, fmt, x)
    resize!(buf, s)
    _fill_buffer!(buf, fmt, x)
    String(buf)
end

function _calculate_buffer_size!(buf, fmt, x::BigFloat)
    ccall((:mpfr_snprintf,:libmpfr),
        Int32, (Ptr{UInt8}, Culong, Ptr{UInt8}, Ref{BigFloat}...),
        buf, 0, fmt, x)
end

function _fill_buffer!(buf, fmt, x::BigFloat)
    s = length(buf)
    # we temporarily need one more item in buffer to capture null termination
    resize!(buf, s + 1)
    n = ccall((:mpfr_sprintf,:libmpfr), Int32, (Ptr{UInt8}, Ptr{UInt8}, Ref{BigFloat}...), buf, fmt, x)
    @assert n + 1 == length(buf)
    @assert last(buf) == 0x00
    resize!(buf, s)
end

function _prettify_bigfloat(s::String)::String
    mantissa, exponent = split(s, 'e')
    if !occursin('.', mantissa)
        mantissa = string(mantissa, '.')
    end
    mantissa = rstrip(mantissa, '0')
    if endswith(mantissa, '.')
        mantissa = string(mantissa, '0')
    end
    if exponent == "+00"
        mantissa
    else
        string(mantissa, 'e', exponent)
    end
end

function _string(x::BigFloat, fmt::String)::String
    isfinite(x) || return string(Float64(x))
    _prettify_bigfloat(string_mpfr(x, fmt))
end
_string(x::BigFloat) = _string(x, "%.Re")
_string(x::BigFloat, k::Integer) = _string(x, "%.$(k)Re")

string(b::BigFloat) = _string(b)

print(io::IO, b::BigFloat) = print(io, string(b))
function show(io::IO, b::BigFloat)
    if get(io, :compact, false)
        print(io, _string(b, 5))
    else
        print(io, _string(b))
    end
end

# get/set exponent min/max
get_emax() = ccall((:mpfr_get_emax, :libmpfr), Clong, ())
get_emax_min() = ccall((:mpfr_get_emax_min, :libmpfr), Clong, ())
get_emax_max() = ccall((:mpfr_get_emax_max, :libmpfr), Clong, ())

get_emin() = ccall((:mpfr_get_emin, :libmpfr), Clong, ())
get_emin_min() = ccall((:mpfr_get_emin_min, :libmpfr), Clong, ())
get_emin_max() = ccall((:mpfr_get_emin_max, :libmpfr), Clong, ())

set_emax!(x) = ccall((:mpfr_set_emax, :libmpfr), Cvoid, (Clong,), x)
set_emin!(x) = ccall((:mpfr_set_emin, :libmpfr), Cvoid, (Clong,), x)

function Base.deepcopy_internal(x::BigFloat, stackdict::IdDict)
    haskey(stackdict, x) && return stackdict[x]
    # d = copy(x._d)
    d = x._d
    d′ = GC.@preserve d unsafe_string(pointer(d), sizeof(d)) # creates a definitely-new String
    y = _BigFloat(x.prec, x.sign, x.exp, d′)
    #ccall((:mpfr_custom_move,:libmpfr), Cvoid, (Ref{BigFloat}, Ptr{Limb}), y, d) # unnecessary
    stackdict[x] = y
    return y
end

function Base.lerpi(j::Integer, d::Integer, a::BigFloat, b::BigFloat)
    t = BigFloat(j)/d
    fma(t, b, fma(-t, a, a))
end

end #module
