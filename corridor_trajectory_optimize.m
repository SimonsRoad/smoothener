% solves the corridor-constrained piecewise polynomial trajectory optimization problem for one robot.
%
% inputs:
%   Arobots, brobots: [DIM x NROBOTS x NSTEPS] and [NROBOTS x NSTEPS]
%                     hyperplanes separating this robot from the other robots at each step
%   Aobs, bobs:       [DIM x <problem-dependent> x NSTEPS] and [<problem-dependent> x NSTEPS]
%                     hyperplanes separating this robot from obstacles at each step.
%                     second dimension is large enough for the polytope with the most faces,
%                     so some rows are allowed to be NaN for polytopes with fewer faces
%   lb, ub:           [3] and [3] lower/upper bound of environment box
%   path:             [3 NSTEPS+1] the discrete plan
%   deg:              [1]        polynomial degree
%   cont:             [1]        derivative continuity (e.g. 2 == cts accel)
%   timescale:        [1]        duration in seconds of step in discrete plan
%   ellipsoid:        [3 1]      radii of robot/robot collision ellipsoid
%   obs_ellipsoid:    [3 1]      radii of robot/obstacle collision ellipsoid
%
% outputs:
%   pp:   a matlab ppform struct containing the trajectory
%   cost: the cost value of the quadratic program
%
function [pp, cost] = corridor_trajectory_optimize(...
	Arobots, brobots, Aobs, bobs, lb, ub, ...
	path, deg, cont, timescale, ellipsoid, obs_ellipsoid)

	[dim, ~, steps] = size(Arobots);
	assert(size(path, 2) == steps + 1);
	init = path(:,1);
	goal = path(:,end);
	order = deg + 1;

	ellipsoid = diag(ellipsoid);
	obs_ellipsoid = diag(obs_ellipsoid);

	% hack - so we can use 7th degree
	ends_zeroderivs = min(3,cont);

	% TODO move this outside
	me = find(isnan(brobots(:,1)));
	assert(length(me) == 1);
	brobots(me,:) = [];
	Arobots(:,me,:) = [];

	% construct the Bernstein polynomials and derivatives
	bern = bernstein(deg);
	for i=1:size(bern,2)
		bern(i,:) = polystretchtime(bern(i,:), timescale);
	end

	bernderivs = repmat(bern, 1, 1, cont + 1);
	for d=2:(cont+1)
		for r=1:order
			p = polyder(bernderivs(r,:,(d-1)));
			p = [zeros(1, order - length(p)), p];
			bernderivs(r,:,d) = p;
		end
	end
	bernderivs = bernderivs(:,:,2:end);
	assert(size(bernderivs, 3) == cont);

	% number of decision variables
	nvars = dim * order * steps;
	lb = repmat(lb, steps * order, 1);
	ub = repmat(ub, steps * order, 1);

	Aineq = {};
	bineq = [];
	Aeq = {};
	beq = [];

	% permutation matrix to convert [xyz xyz xyz]' into [xxx yyy zzz]'
	dim_collect_one_step = dim_collect_matrix(dim, order);

	% time vectors at start and end
	t0 = 0 .^ (deg:(-1):0);
	t1 = timescale .^ (deg:(-1):0);

	for step=1:steps
		dim_select = 1:steps == step;
		dim_collect = kron(dim_select, dim_collect_one_step);
		dim_collect_prev = kron((1:steps == (step-1)), dim_collect_one_step);

		% offset the corridor bounding polyhedra by the ellipsoid
		Astep = [Arobots(:,:,step)'; Aobs(:,:,step)'];
		bstep = [polytope_erode_by_ellipsoid(Arobots(:,:,step)', brobots(:,step), ellipsoid); ...
		         polytope_erode_by_ellipsoid(Aobs(:,:,step)', bobs(:,step), obs_ellipsoid)];

		% delete NaN inputs coming from "ragged" Aobs, bobs
		nan_rows = isnan(bstep);
		Astep(nan_rows,:) = [];
		bstep(nan_rows) = [];

		% try to eliminate redundant half-space constraints
		interior_pt = (path(:,step) + path(:,step+1)) ./ 2;
		[Astep,bstep] = noredund(Astep,bstep,interior_pt);

		% add bounding polyhedron constraints on control points
		Aineq = [Aineq; kron(dim_select, kron(eye(order), Astep))];
		bineq = [bineq; repmat(bstep, order, 1)];

		if step == 1
			% initial position and 0 derivatives
			Aeq = [Aeq; kron(eye(dim), t0 * bern') * dim_collect];
			beq = [beq; init];
			for d=1:ends_zeroderivs
				Aeq = [Aeq; kron(eye(dim), t0 * bernderivs(:,:,d)') * dim_collect];
				beq = [beq; zeros(dim,1)];
			end
		else
			% continuity with previous
			A_sub = kron(eye(dim), t0 * bern') * dim_collect - ...
					kron(eye(dim), t1 * bern') * dim_collect_prev;
			Aeq = [Aeq; A_sub];
			beq = [beq; zeros(dim,1)];
			for d=1:cont
				A_sub = kron(eye(dim), t0 * bernderivs(:,:,d)') * dim_collect - ...
						kron(eye(dim), t1 * bernderivs(:,:,d)') * dim_collect_prev;
				Aeq = [Aeq; A_sub];
				beq = [beq; zeros(dim,1)];
			end
		end

		if step == steps
			% goal position and 0 derivatives
			Aeq = [Aeq; kron(eye(dim), t1 * bern') * dim_collect];
			beq = [beq; goal];
			for d=1:ends_zeroderivs
				Aeq = [Aeq; kron(eye(dim), t1 * bernderivs(:,:,d)') * dim_collect];
				beq = [beq; zeros(dim,1)];
			end
		end
	end

	Aineq = cat(1, Aineq{:});
	Aeq = cat(1, Aeq{:});
	assert(size(Aineq, 2) == nvars);
	assert(size(Aineq, 1) == length(bineq));
	assert(size(Aeq, 2) == nvars);
	assert(size(Aeq, 1) == length(beq));

	coef_cost = ...
		1 * int_sqr_deriv_matrix(deg, 2, timescale) + ...
		0 * int_sqr_deriv_matrix(deg, 3, timescale) + ...
		5e-3 * int_sqr_deriv_matrix(deg, 4, timescale);
	piece_to_coefs = kron(eye(dim), bern') * dim_collect_one_step;
	piece_cost = piece_to_coefs' * kron(eye(dim), coef_cost) * piece_to_coefs;
	Q = kron(eye(steps), piece_cost);
	Q = Q + Q'; % matlab complains, but error is small. TODO track down source.

	options = optimoptions('quadprog', 'Display', 'off');
	options.TolCon = options.TolCon / 10;

	% DEBUGGING INFEASIBLE
	%x_ineq = linprog(zeros(1,nvars), Aineq, bineq);
	%x_ineq_err = bineq - Aineq*x_ineq;
	%x_eq = Aeq\beq;
	%x_all = linprog(zeros(1,nvars), Aineq, bineq, Aeq, beq, lb, ub);

	if exist('cplexqp')
		[x, cost] = cplexqp(Q, zeros(1,nvars), Aineq, bineq, Aeq, beq, lb, ub);
	else
		[x, cost] = quadprog(sparse(Q), zeros(1,nvars), ...
			sparse(Aineq), sparse(bineq), sparse(Aeq), sparse(beq), ...
			lb, ub, [], options);
	end

	% x is [dim, ctrlpoint, piece] - want [dim, piece, degree]
	x = reshape(x, [dim*order, steps]);
	coefs = [];
	for piece=1:steps
		xx = reshape(dim_collect_one_step * x(:,piece), [order dim]);
		piece_coefs = bern' * xx; % [order dim]
		coefs = cat(2, coefs, reshape(piece_coefs', [dim 1 order]));
	end

	breaks = timescale * (0:steps);
	pp = mkpp(breaks, coefs, dim);
end
