#init 
using TetrisAI
using JSON
using Dates

import TetrisAI: game_over, set_game, data_list

const DATA_PATH = joinpath(TetrisAI.PROJECT_ROOT, "data")
const STATES_PATH = joinpath(DATA_PATH, "states")
const LABELS_PATH = joinpath(DATA_PATH, "labels")
const json = ".json"

global game = TetrisGame()
global Paused = false
global input = :nothing
global GUI = TetrisUI()
global states = []
global labels = []
global index = 0

const input_dict = Dict(
    :nothing => 1,   
    :move_left => 2,
    :move_right => 3,
    :hard_drop => 4,
    :rotate_clockwise => 5,
    :rotate_counter_clockwise => 6,
    :hold_piece => 7
)

WIDTH = 1000
HEIGHT = 1000

"""
    on_key_down(g::Game, k)


Checks for keyboard input.
"""
function on_key_down(g::Game, k)
    global game, Paused, input
    # Pause, debug and quit
    if k == Keys.P
        if game.is_over
            # Writes training_data to file
            save_training_data()

            # Resets the game when game is over
            reset!(game)
            input = :nothing
        else
            # Pauses or unpauses the game
            Paused = !Paused
        end
    end
    if k == Keys.D
        # Debug print
        println(game)
    end
    if k == Keys.Q
        # Quits the game (exits the julia environment)
        exit()
    end
    # Tetris Input
    if !Paused && !game.is_over
        if (k == Keys.LEFT)
            input = :move_left
        elseif (k == Keys.RIGHT)
            input = :move_right
        elseif (k == Keys.UP || k == Keys.X)
            input = :rotate_clockwise
        elseif (k == Keys.DOWN)
            input = :rotate_counter_clockwise
        elseif (k == Keys.SPACE)
            input = :hard_drop
        elseif (k == Keys.LSHIFT || k == Keys.C)
            input = :hold_piece
        end
    end
end

"""
    save_training_data()

Create file's suffix name and pass data for upload
"""
function save_training_data()

    suffix = Dates.format(DateTime(now()), "yyyymmddHHMMSS")
    stateFile = "states_$suffix$json"
    actionFile = "actions_$suffix$json"

    stateFileName = joinpath(STATES_PATH, stateFile)
    actionFileName = joinpath(LABELS_PATH, actionFile)

    training_data = Dict(
        "suffix" => suffix,
        "score" => game.score,
        "stateFile" => stateFile,
        "actionFile" => actionFile,
        "stateFileName" => stateFileName,
        "actionFileName" => actionFileName,
        "states" => states,
        "labels" => labels
    )

    push!(data_list, training_data)
end

"""
    draw(g::Game)

Base GameZero.jl function, called every frame. Draws everything on screen.
"""
function draw(g::Game)
    global game, Paused, GUI
    TetrisAI.GUI.drawUI(GUI,game,Paused)
end

"""
    update(g::Game)

Base GameZero.jl function, called every frame. Updates the game state.
"""
function update(g::Game)
    global game, Paused, input, agent, states, labels, index
    if !Paused && !game.is_over
        
        # Right now we are only interested in non nothing moves
        if input != :nothing
            # Save training data
            state = get_state(game)
            label = input_dict[input]
            push!(states, (index, state))
            push!(labels, (index, label))
            index += 1
        end


        # Sends input and get new state
        send_input!(game, input)
        _, _, _ = tick!(game)

        # Reset input for next tick
        input = :nothing
        # Check for constant input for soft drop
        if g.keyboard.Z || g.keyboard.LCTRL 
            send_input!(game, :nothing)
            tick!(game)
        end
    end
end
