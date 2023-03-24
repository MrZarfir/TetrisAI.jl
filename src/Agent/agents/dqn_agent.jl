using CUDA
using Flux: gpu, cpu
using Flux: onehotbatch, onecold
using Flux.Data: DataLoader
using Flux.Losses: logitcrossentropy

# Should be refactored
const DATA_PATH = joinpath(TetrisAI.PROJECT_ROOT, "data")
const STATES_PATH = joinpath(DATA_PATH, "states")
const LABELS_PATH = joinpath(DATA_PATH, "labels")

if CUDA.functional()
    CUDA.allowscalar(false)
    device = gpu
else
    device = cpu
end

#TODO: fix gamma and alpha
Base.@kwdef mutable struct DQNAgent <: AbstractAgent
    type::String = "SARSA"
    n_games::Int = 0
    record::Int = 0
    current_score::Int = 0
    feature_extraction::Bool = false
    reward_shaping::Bool = false
    ω::Float64 = 0              # Reward shaping constant
    η::Float64 = 1e-3           # Learning rate
    γ::Float64 = (1 - 1e-2)     # Discount factor
    ϵ::Float64 = 1              # Exploration
    ϵ_decay::Float64 = 1
    ϵ_min::Float64 = 0.05
    memory::AgentMemory = CircularBufferMemory()
    main_net = TetrisAI.Model.dense_net(228, 7)
    target_net = TetrisAI.Model.dense_net(228, 7)
    opt::Flux.Optimise.AbstractOptimiser = Flux.ADAM(η)
    loss::Function = logitcrossentropy
end

function get_action(agent::DQNAgent, state::AbstractArray{<:Integer}; rand_range=1:200, nb_outputs=7)
    agent.ϵ = 80 - agent.n_games
    final_move = zeros(Int, nb_outputs)

    if rand(rand_range) < agent.ϵ
        # Random move for exploration
        move = rand(1:nb_outputs)
        final_move[move] = 1
    else
        state = state |> device
        pred = agent.model(state)
        pred = pred |> cpu
        final_move[Flux.onecold(pred)] = 1
    end

    return final_move
end

function train!(agent::DQNAgent, game::TetrisAI.Game.AbstractGame)

    # Get the current step
    old_state = TetrisAI.Game.get_state(game)
    if agent.feature_extraction
        old_state = get_state_features(old_state, game.active_piece.row, game.active_piece.col)
    end

    # Get the predicted move for the state
    action = get_action(agent, old_state)
    TetrisAI.send_input!(game, action)

    reward = 0
    # Play the step
    lines, done, score = TetrisAI.Game.tick!(game)
    new_state = TetrisAI.Game.get_state(game)

    # Adjust reward accoring to amount of lines cleared
    if agent.reward_shaping
        reward = shape_rewards(game, lines)
    else
        if lines > 0
            reward = [1, 5, 10, 50][lines]
        end
    end

    # Train the short memory
    train_short_memory(agent, old_state, action, reward, new_state, done)

    # Remember
    remember(agent, old_state, action, reward, new_state, done)

    if done
        # Reset the game
        train_long_memory(agent)
        TetrisAI.Game.reset!(game)
        agent.n_games += 1

        if score > agent.record
            agent.record = score
        end
    end

    return done, score
end

function train_memory(
    agent::DQNAgent,
    old_state::S,
    move::S,
    reward::T,
    new_state::S,
    done::Bool
) where {T<:Integer,S<:AbstractArray{<:T}}
    # Train the short memory
    train_short_memory(agent, old_state, move, reward, new_state, done)
    # Remember
    remember(agent, old_state, move, reward, new_state, done)
    if done
        train_long_memory(agent)
    end
end

function remember(
    agent::DQNAgent,
    state::S,
    action::S,
    reward::T,
    next_state::S,
    done::Bool
) where {T<:Integer,S<:AbstractArray{<:T}}
    push!(agent.memory.data, (state, action, [reward], next_state, convert.(Int, [done])))
end

function train_short_memory(
    agent::DQNAgent,
    state::S,
    action::S,
    reward::T,
    next_state::S,
    done::Bool
) where {T<:Integer,S<:AbstractArray{<:T}}
    update!(agent, state, action, reward, next_state, done)
end

function train_long_memory(agent::DQNAgent)
    if length(agent.memory.data) > BATCH_SIZE
        mini_sample = sample(agent.memory.data, BATCH_SIZE)
    else
        mini_sample = agent.memory.data
    end

    states, actions, rewards, next_states, dones = map(x -> getfield.(mini_sample, x), fieldnames(eltype(mini_sample)))

    update!(agent, states, actions, rewards, next_states, dones)
end

function update!(
    agent::DQNAgent,
    state::Union{A,AA},
    action::Union{A,AA},
    reward::Union{T,AA},
    next_state::Union{A,AA},
    done::Union{Bool,AA};
    α::Float32=0.9f0    # Step size
) where {T<:Integer,A<:AbstractArray{<:T},AA<:AbstractArray{A}}

    # Batching the states and converting data to Float32 (done implicitly otherwise)
    state = Flux.batch(state) |> x -> convert.(Float32, x) |> device
    next_state = Flux.batch(next_state) |> x -> convert.(Float32, x) |> device
    action = Flux.batch(action) |> x -> convert.(Float32, x)
    reward = Flux.batch(reward) |> x -> convert.(Float32, x)
    done = Flux.batch(done)

    # Model's prediction for next state
    y = agent.model(next_state) 
    y = y |> cpu

    # Get the model's params for back propagation
    ps = Flux.params(agent.model)

    # Calculate the gradients
    gs = Flux.gradient(ps) do
        # Forward pass
        ŷ = agent.model(state)
        ŷ = ŷ |> cpu

        # Creating buffer to allow mutability when calculating gradients
        Rₙ = Buffer(ŷ, size(ŷ))

        # Adjusting values of current state with next state's knowledge
        for idx in eachindex(done)
            # Copy preds into buffer
            Rₙ[:, idx] = ŷ[:, idx]

            Qₙ = reward[idx]
            if done[idx] == false
                Qₙ += α * maximum(y[:, idx])
            end

            # Adjusting the expected reward for selected move
            Rₙ[argmax(action[:, idx]), idx] = Qₙ
        end
        # Calculate the loss
        agent.loss(ŷ |> device, copy(Rₙ) |> device)
    end

    # Update model weights
    Flux.Optimise.update!(agent.opt, ps, gs)
end

"""
Clones behavior from expert data to policy neural net
"""
function clone_behavior!(
    agent::DQNAgent, 
    lr::Float64 = 5e-4, 
    batch_size::Int64 = 50, 
    epochs::Int64 = 80)

    if agent.feature_extraction
        # 17 here is subject to change
        states = Array{Real,2}(undef,17,0)
    else
        states = Array{Real,2}(undef,228,0)
    end
    labels = Array{Real,2}(undef,1,0)

    n_states = 0

    # Ignore hidden files
    states_files = [joinpath(STATES_PATH, file) for file in readdir(STATES_PATH) if startswith(file, ".") == false]
    labels_files = [joinpath(LABELS_PATH, file) for file in readdir(LABELS_PATH) if startswith(file, ".") == false]

    for file in states_files
        states_data = JSON.parse(readline(file), dicttype=Dict{String,Vector{Int64}})
        for state in states_data
            state = (state |> values |> collect)[1]
            if agent.feature_extraction
                state = state |> get_state_features
            end
            n_states += 1
            states = hcat(states, state)
        end
    end

    for file in labels_files
        labels_data = JSON.parse(readline(file), dicttype=Dict{String,Int64})
        for label in labels_data
            label = label |> values |> collect
            labels = hcat(labels, label)
        end
    end

    # Convert labels to onehot vectors
    labels = dropdims(Flux.onehotbatch(labels,1:7);dims=2)

    # Homemade split to have at least a testing metric
    train_states = states[:, begin:end - 101] |> device
    train_labels = labels[:, begin:end - 101] |> device
    test_states = states[:, end - 100:end] |> device
    test_labels = labels[:, end - 100:end] |> device

    train_loader = DataLoader((train_states, train_labels), batchsize = batch_size, shuffle = true)
    test_loader = DataLoader((test_states, test_labels), batchsize = batch_size)

    to_device!(agent)

    ps = Flux.params(agent.main_net) # model's trainable parameters

    loss = Flux.Losses.logitcrossentropy

    opt = Flux.ADAM(lr)

    iter = ProgressBar(1:epochs)
    println("Pre-training the model on $epochs epochs, with $n_states states.")
    set_description(iter, "Epoch: 0/$epochs:")
    for it in iter
        set_description(iter, "Epoch: $it/$epochs:")
        for (x, y) in train_loader
            gs = Flux.gradient(ps) do
                    ŷ = agent.main_net(x)
                    loss(ŷ, y)
                end

            Flux.Optimise.update!(opt, ps, gs)
        end
    end

    # Testing the model
    acc = 0.0
	n = 0
	
	for (x, y) in test_loader
		ŷ = agent.model(x)

		# Comparing the model's predictions with the labels
		acc += sum(onecold(ŷ |> cpu ) .== onecold(y |> cpu))

		# keeping track of the number of pictures we tested
		n += size(x)[end]
	end

    println("Final accuracy : ", acc/n * 100, "%")

    agent.target_net = agent.main_net

    return agent
end

function to_device!(agent::DQNAgent) 
    agent.main_net = agent.main_net |> device
    agent.target_net = agent.target_net |> device
end
