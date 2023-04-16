using CUDA
using Flux: gpu, cpu
using Flux: onehotbatch, onecold
using Flux.Losses: logitcrossentropy

if CUDA.functional()
    CUDA.allowscalar(false)
    device = gpu
else
    device = cpu
end

#TODO: fix gamma and alpha
Base.@kwdef mutable struct SARSAAgent <: AbstractAgent 
    type::String = "SARSA"
    n_games::Int = 0
    record::Int = 0
    current_score::Int = 0
    feature_extraction::Bool = true
    n_features::Int = 17
    reward_shaping::Bool = false
    ω::Float64 = 0              # Reward shaping constant
    η::Float64 = 1e-3           # Learning rate
    γ::Float64 = (1 - 1e-2)     # Discount factor
    ϵ::Float64 = 1              # Exploration
    ϵ_decay::Float64 = 0.001
    ϵ_min::Float64 = 0.005
    model = (feature_extraction ? TetrisAI.Model.dense_net(n_features, 7) : TetrisAI.Model.dense_net(228, 7)) |> device
    opt::Flux.Optimise.AbstractOptimiser = Flux.ADAM(η)
    loss::Function = logitcrossentropy
end

"""
    get_action(agent::SARSAAgent, state::AbstractArray{<:Real}, nb_outputs::Integer=7)

TBW
"""
function get_action(agent::SARSAAgent, state::AbstractArray{<:Real}, nb_outputs::Integer=7)
    final_move = zeros(Int, nb_outputs)

    if rand() < agent.ϵ
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

"""
    train!(agent::SARSAAgent, game::TetrisAI.Game.AbstractGame)

TBW
"""
function train!(agent::SARSAAgent, game::TetrisAI.Game.AbstractGame)

    # Get the current step
    old_state = TetrisAI.Game.get_state(game)
    if agent.feature_extraction
        old_state = get_state_features(old_state, game.active_piece.row, game.active_piece.col)
    end

    # Get the predicted move for the state
    action = get_action(agent, old_state)
    TetrisAI.send_input!(game, action)

    # Play the step
    lines, done, score = TetrisAI.Game.tick!(game)
    new_state = TetrisAI.Game.get_state(game)
    if agent.feature_extraction
        new_state = get_state_features(new_state, game.active_piece.row, game.active_piece.col)
    end

    reward = 0
    # Adjust reward accoring to amount of lines cleared
    if agent.reward_shaping
        reward = shape_rewards(game, lines)
    else
        if lines > 0
            reward = [1, 5, 10, 50][lines]
        end
    end

    # Update
    update!(agent, old_state, action, reward, new_state, done)

    if agent.ϵ > agent.ϵ_min
        agent.ϵ -= agent.ϵ_decay
    end

    if done
        # Reset the game
        TetrisAI.Game.reset!(game)
        agent.n_games += 1

        if score > agent.record
            agent.record = score
        end
    end

    return done, score
end

"""
    update!(
        agent::SARSAAgent,
        state::Union{A,AA},
        action::Union{A,AA},
        reward::Union{T,AA},
        next_state::Union{A,AA},
        done::Union{Bool,AA};
        α::Float32=0.9f0) where {T<:Real,A<:AbstractArray{<:T},AA<:AbstractArray{A}}

Update SARSA
"""
function update!(
    agent::SARSAAgent,
    state::Union{A,AA},
    action::Union{A,AA},
    reward::Union{T,AA},
    next_state::Union{A,AA},
    done::Union{Bool,AA};
    α::Float32=0.9f0    # Step size
) where {T<:Real,A<:AbstractArray{<:T},AA<:AbstractArray{A}}

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
    clone_behavior!(
        agent::SARSAAgent,
        lr::Float64 = 5e-4, 
        batch_size::Int64 = 50, 
        epochs::Int64 = 80)

Clones behavior from expert data to policy neural net
"""
function clone_behavior!(
    agent::SARSAAgent,
    lr::Float64 = 5e-4, 
    batch_size::Int64 = 50, 
    epochs::Int64 = 80)

    agent.model = clone_behavior!(agent, agent.model, lr , batch_size, epochs)

    return agent
end

"""
    to_device!(agent::SARSAAgent)

TBW
"""
function to_device!(agent::SARSAAgent) 
    agent.model = agent.model |> device
end
