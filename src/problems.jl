"""
$(TYPEDEF)

Structure to hold the bifurcation problem. If don't have parameters, you can pass `nothing`.

## Fields

$(TYPEDFIELDS)

## Methods

- `getu0(pb)` calls `pb.u0`
- `getParams(pb)` calls `pb.params`
- `getLens(pb)` calls `pb.lens`
- `getParam(pb)` calls `get(pb.params, pb.lens)`
- `setParam(pb, p0)` calls `set(pb.params, pb.lens, p0)`
- `recordFromSolution(pb)` calls `pb.recordFromSolution`
- `plotSolution(pb)` calls `pb.plotSolution`
- `isSymmetric(pb)` calls `isSymmetric(pb.prob)`

## Constructors

- `BifurcationProblem(F, u0, params, lens; J, Jᵗ, d2F, d3F, kwargs...)` and `kwargs` are the fields above.

"""
struct ConstantDDEBifProblem{Tvf, Tdf, Tu, Td, Tp, Tl <: Lens, Tplot, Trec} <: BifurcationKit.AbstractBifurcationProblem
	"Vector field, typically a [`BifFunction`](@ref)"
	VF::Tvf
	"function delays"
	delays::Tdf
	"Initial guess"
	u0::Tu
	"initial delays"
	delays0::Td
	"parameters"
	params::Tp
	"Typically a `Setfield.Lens`. It specifies which parameter axis among `params` is used for continuation. For example, if `par = (α = 1.0, β = 1)`, we can perform continuation w.r.t. `α` by using `lens = (@lens _.α)`. If you have an array `par = [ 1.0, 2.0]` and want to perform continuation w.r.t. the first variable, you can use `lens = (@lens _[1])`. For more information, we refer to `SetField.jl`."
	lens::Tl
	"user function to plot solutions during continuation. Signature: `plotSolution(x, p; kwargs...)`"
	plotSolution::Tplot
	"`recordFromSolution = (x, p) -> norm(x)` function used record a few indicators about the solution. It could be `norm` or `(x, p) -> x[1]`. This is also useful when saving several huge vectors is not possible for memory reasons (for example on GPU...). This function can return pretty much everything but you should keep it small. For example, you can do `(x, p) -> (x1 = x[1], x2 = x[2], nrm = norm(x))` or simply `(x, p) -> (sum(x), 1)`. This will be stored in `contres.branch` (see below). Finally, the first component is used to plot in the continuation curve."
	recordFromSolution::Trec
end

BK.isInplace(::ConstantDDEBifProblem) = false
BK.isSymmetric(::ConstantDDEBifProblem) = false
BK.getVectorType(prob::ConstantDDEBifProblem{Tvf, Tdf, Tu, Td, Tp, Tl, Tplot, Trec}) where {Tvf, Tdf, Tu, Td, Tp, Tl <: Lens, Tplot, Trec} = Tu
BK.getLens(prob::ConstantDDEBifProblem) = prob.lens
BK.hasAdjoint(prob::ConstantDDEBifProblem) = true

function Base.show(io::IO, prob::ConstantDDEBifProblem; prefix = "")
	print(io, prefix * "┌─ Constant Delays Bifurcation Problem with uType ")
	printstyled(io, getVectorType(prob), color=:cyan, bold = true)
	print(io, prefix * "\n├─ Inplace:  ")
	printstyled(io, isInplace(prob), color=:cyan, bold = true)
	# printstyled(io, isSymmetric(prob), color=:cyan, bold = true)
	print(io, "\n" * prefix * "└─ Parameter: ")
	printstyled(io, BifurcationKit.getLensSymbol(getLens(prob)), color=:cyan, bold = true)
end

struct JacobianConstantDDE{Tp,T1,T2,T3,Td}
	prob::Tp
	Jall::T1
	J0::T2
	Jd::T3
	delays::Td
end

function ConstantDDEBifProblem(F, delayF, u0, delays0, parms, lens = (@lens _);
				dF = nothing,
				dFad = nothing,
				J = nothing,
				Jᵗ = nothing,
				d2F = nothing,
				d3F = nothing,
				issymmetric::Bool = false,
				recordFromSolution = BifurcationKit.recordSolDefault,
				plotSolution = BifurcationKit.plotDefault,
				inplace = false)
	J = isnothing(J) ? (x,p) -> ForwardDiff.jacobian(z -> F(z, p), x) : J
	dF = isnothing(dF) ? (x,p,dx) -> ForwardDiff.derivative(t -> F(x .+ t .* dx, p), 0.) : dF
	d1Fad(x,p,dx1) = ForwardDiff.derivative(t -> F(x .+ t .* dx1, p), 0.)
	if isnothing(d2F)
		d2F = (x,p,dx1,dx2) -> ForwardDiff.derivative(t -> d1Fad(x .+ t .* dx2, p, dx1), 0.)
		d2Fc = (x,p,dx1,dx2) -> BilinearMap((_dx1, _dx2) -> d2F(x,p,_dx1,_dx2))(dx1,dx2)
	else
		d2Fc = d2F
	end
	if isnothing(d3F)
		d3F  = (x,p,dx1,dx2,dx3) -> ForwardDiff.derivative(t -> d2F(x .+ t .* dx3, p, dx1, dx2), 0.)
		d3Fc = (x,p,dx1,dx2,dx3) -> TrilinearMap((_dx1, _dx2, _dx3) -> d3F(x,p,_dx1,_dx2,_dx3))(dx1,dx2,dx3)
	else
		d3Fc = d3F
	end

	d3F = isnothing(d3F) ? (x,p,dx1,dx2,dx3) -> ForwardDiff.derivative(t -> d2F(x .+ t .* dx3, p, dx1, dx2), 0.) : d3F
	VF = BifFunction(F, dF, dFad, J, Jᵗ, d2F, d3F, d2Fc, d3Fc, issymmetric, 1e-8, inplace)
	return ConstantDDEBifProblem(VF, delayF, u0, delays0, parms, lens, plotSolution, recordFromSolution)
end


function BK.residual(prob::ConstantDDEBifProblem, x, p)
	xd = VectorOfArray([x for _ in eachindex(prob.delays0)])
	prob.VF.F(x,xd,p)
end

function BK.jacobian(prob::ConstantDDEBifProblem, x, p)
	xd = VectorOfArray([x for _ in eachindex(prob.delays0)])
	J0 = ForwardDiff.jacobian(z -> prob.VF.F(z, xd, p), x)

	Jd = [ ForwardDiff.jacobian(z -> prob.VF.F(x, (@set xd[ii] = z), p), x) for ii in eachindex(prob.delays0)]
	return JacobianConstantDDE(prob, J0 + sum(Jd), J0, Jd, prob.delays(prob.delays0,p))
end

function jad(prob::ConstantDDEBifProblem, x, p)
	J = BK.jacobian(prob, x, p)
	J.Jall .= J.Jall'
	J.J0 .= J.J0'
	for _J in J.Jd
		_J .= _J'
	end
	J
end

function Δ(prob::ConstantDDEBifProblem, x, p, v, λ)
	J = BK.jacobian(prob, x, p)
	res = λ .* v .- J.J0*v
	for (ind, A) in pairs(J.Jd)
		res .-= exp(-λ * J.delays[ind]) .* (A * v)
	end
	res
end
