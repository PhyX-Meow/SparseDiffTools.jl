struct ForwardColorJacCache{T,T2,T3,T4,T5,T6}
    t::T
    fx::T2
    dx::T3
    p::T4
    colorvec::T5
    sparsity::T6
    chunksize::Int
end

function default_chunk_size(maxcolor)
    if maxcolor < DEFAULT_CHUNK_THRESHOLD
        Val(maxcolor)
    else
        Val(DEFAULT_CHUNK_THRESHOLD)
    end
end

getsize(::Val{N}) where N = N
getsize(N::Integer) = N

function ForwardColorJacCache(f,x,_chunksize = nothing;
                              dx = nothing,
                              colorvec=1:length(x),
                              sparsity::Union{AbstractArray,Nothing}=nothing)

    if _chunksize === nothing
        chunksize = default_chunk_size(maximum(colorvec))
    else
        chunksize = _chunksize
    end

    p = adapt.(typeof(x),generate_chunked_partials(x,colorvec,chunksize))
    t = reshape(Dual{typeof(f)}.(vec(x),first(p)),size(x)...)

    if dx === nothing
        fx = similar(t)
        _dx = similar(x)
    else
        fx = reshape(Dual{typeof(f)}.(vec(dx),first(p)),size(x)...)
        _dx = dx
    end

    ForwardColorJacCache(t,fx,_dx,p,colorvec,sparsity,getsize(chunksize))
end

generate_chunked_partials(x,colorvec,N::Integer) = generate_chunked_partials(x,colorvec,Val(N))
function generate_chunked_partials(x,colorvec,::Val{chunksize}) where chunksize
    maxcolor = maximum(colorvec)
    num_of_chunks = Int(ceil(maxcolor / chunksize))
    padding_size = (chunksize - (maxcolor % chunksize)) % chunksize
    partials = colorvec .== (1:maxcolor)'
    padding_matrix = BitMatrix(undef, length(x), padding_size)
    partials = hcat(partials, padding_matrix)

    chunked_partials = map(i -> Tuple.(eachrow(partials[:,(i-1)*chunksize+1:i*chunksize])),1:num_of_chunks)
    chunked_partials

end

function forwarddiff_color_jacobian(f,
                x::AbstractArray{<:Number};
                dx = nothing,
                colorvec = 1:length(x),
                sparsity = nothing,
                jac_prototype = nothing)
    forwarddiff_color_jacobian(f,x,ForwardColorJacCache(f,x,dx=dx,colorvec=colorvec,sparsity=sparsity),jac_prototype)
end

function forwarddiff_color_jacobian(f,x::AbstractArray{<:Number},jac_cache::ForwardColorJacCache,jac_prototype=nothing)
    t = jac_cache.t
    fx = jac_cache.fx
    dx = jac_cache.dx
    p = jac_cache.p
    colorvec = jac_cache.colorvec
    sparsity = jac_cache.sparsity
    chunksize = jac_cache.chunksize
    color_i = 1
    maxcolor = maximum(colorvec)

    vecx = vec(x)
    
    ncols=length(x)
    J = jac_prototype isa Nothing ? false .* x .* x' : zero(jac_prototype)

    if !(sparsity isa Nothing)
        rows_index, cols_index = ArrayInterface.findstructralnz(sparsity)
    end

    for i in eachindex(p)
        partial_i = p[i]
        t = reshape(Dual{typeof(f)}.(vecx, partial_i),size(t))
        fx = f(t)
        if !(sparsity isa Nothing)
            for j in 1:chunksize
                dx = vec(partials.(fx, j))
                coords = [(rows_index[i],cols_index[i]) for i in 1:length(cols_index) if colorvec[cols_index[i]] == color_i ]
                rows_index_c = [coord[1] for coord in coords]
                len_rows = length(rows_index_c)
                unused_rows = setdiff(1:ncols,rows_index_c)
                perm_rows = sortperm([i<=len_rows ? rows_index_c[i] : unused_rows[i-len_rows] for i in 1:ncols])
                cols_index_c = [i<=len_rows ? coords[i][2] : false for i in 1:ncols][perm_rows]
                Ji = [j==cols_index_c[i] ? dx[i] : false for i in 1:ncols, j in 1:ncols]
                J = J + Ji
                color_i += 1
                (color_i > maxcolor) && return J
            end
        else
            for j in 1:chunksize
                col_index = (i-1)*chunksize + j
                (col_index > maxcolor) && return J
                J = J + partials.(vec(fx), j) .* [(i==col_index ? 1 : 0) for i in 1:ncols]'
            end
        end
    end
    J
end

function forwarddiff_color_jacobian!(J::AbstractMatrix{<:Number},
                f,
                x::AbstractArray{<:Number};
                dx = nothing,
                colorvec = 1:length(x),
                sparsity = ArrayInterface.has_sparsestruct(J) ? J : nothing)
    forwarddiff_color_jacobian!(J,f,x,ForwardColorJacCache(f,x,dx=dx,colorvec=colorvec,sparsity=sparsity))
end

function forwarddiff_color_jacobian!(J::AbstractMatrix{<:Number},
                f,
                x::AbstractArray{<:Number},
                jac_cache::ForwardColorJacCache)

    t = jac_cache.t
    fx = jac_cache.fx
    dx = jac_cache.dx
    p = jac_cache.p
    colorvec = jac_cache.colorvec
    sparsity = jac_cache.sparsity
    chunksize = jac_cache.chunksize
    color_i = 1
    maxcolor = maximum(colorvec)
    fill!(J, zero(eltype(J)))

    if DiffEqDiffTools._use_findstructralnz(sparsity)
        rows_index, cols_index = ArrayInterface.findstructralnz(sparsity)
    else
        rows_index = nothing
        cols_index = nothing
    end

    vecx = vec(x)
    vect = vec(t)
    vecfx= vec(fx)
    vecdx= vec(dx)

    ncols=size(J,2)

    for i in eachindex(p)
        partial_i = p[i]
        vect .= Dual{typeof(f)}.(vecx, partial_i)
        f(fx,t)
        if !(sparsity isa Nothing)
            for j in 1:chunksize
                dx .= partials.(fx, j)
                if ArrayInterface.fast_scalar_indexing(dx)
                    #dx is implicitly used in vecdx
                    DiffEqDiffTools._colorediteration!(J,sparsity,rows_index,cols_index,vecdx,colorvec,color_i,ncols)
                else
                    #=
                    J.nzval[rows_index] .+= (colorvec[cols_index] .== color_i) .* dx[rows_index]
                    or
                    J[rows_index, cols_index] .+= (colorvec[cols_index] .== color_i) .* dx[rows_index]
                    += means requires a zero'd out start
                    =#
                    if J isa SparseMatrixCSC
                        @. setindex!((J.nzval,),getindex((J.nzval,),rows_index) + (getindex((colorvec,),cols_index) == color_i) * getindex((vecdx,),rows_index),rows_index)
                    else
                        @. setindex!((J,),getindex((J,),rows_index, cols_index) + (getindex((colorvec,),cols_index) == color_i) * getindex((vecdx,),rows_index),rows_index, cols_index)
                    end
                end
                color_i += 1
                (color_i > maxcolor) && return
            end
        else
            for j in 1:chunksize
                col_index = (i-1)*chunksize + j
                (col_index > maxcolor) && return
                J[:, col_index] .= partials.(vecfx, j)
            end
        end
    end
    nothing
end
