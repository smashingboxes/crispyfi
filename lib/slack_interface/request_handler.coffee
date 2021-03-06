class SlackInterfaceRequestHandler
  constructor: (auth, spotify, volume) ->
    @auth = auth
    @spotify = spotify
    @volume = volume
    @plugin_handler = require("../../lib/plugin_handler")()

    @endpoints =
      handle:
        post: (request, response) =>
          request.resume()
          request.once "end", =>
            return if !@auth.validate(request, response)

            reply_data = { ok: true }

            return if @auth.user_name == 'slackbot'

            switch @auth.command.toLowerCase()
              when 'pause' then @spotify.pause()
              when 'stop' then @spotify.stop()
              when 'skip'
                message = @spotify.skip(@auth.user_name)
                if typeof(message) == 'string'
                  reply_data['text'] = message
              when 'reconnect' then @spotify.connect()
              when 'restart' then process.exit 1
              when 'mute' then @volume.set 0
              when 'unmute' then @volume.set 5

              when 'queue'
                if @auth.args[0]?
                  @spotify.pushQueue(@auth.args[0])
                  reply_data['text'] = "OK"
                else
                  queued_tracks = @spotify.showQueue()
                  reply_data['text'] = ":musical_note: Queued Tracks :musical_note:\n"
                  queued_tracks.forEach( (track, index) ->
                    reply_data['text'] += "#{index + 1}. #{track.name} *#{track.artists[0].name}* [#{track.album.name}]\n"
                  )

              when 'play'
                if @auth.args[0]? && @spotify.queue.length() > 0
                  reply_data['text'] = "Please use the queue."
                else if @auth.args[0]?
                  @spotify.play @auth.args[0]
                else
                  @spotify.play()

              when 'random'
                @spotify.toggle_random()
                reply_data['text'] = if @spotify.state.random
                    "CHAOS"
                  else
                    "Don't be a square."

              when 'shuffle'
                @spotify.toggle_shuffle()
                reply_data['text'] = if @spotify.state.shuffle
                    "ERRYDAY I'M SHUFFLING."
                  else
                    "I am no longer shuffling. Thanks for ruining my fun."

              when 'vol'
                if @auth.args[0]?
                  switch @auth.args[0]
                    when "up" then @volume.up()
                    when "down" then @volume.down()
                    else @volume.set @auth.args[0]
                else
                  reply_data['text'] = "Current Volume: *#{@volume.current_step}*"

              when 'list'
                if @auth.args[0]?
                  switch @auth.args[0]
                    when 'add' then status = @spotify.add_playlist @auth.args[1], @auth.args[2]
                    when 'remove' then status = @spotify.remove_playlist @auth.args[1]
                    when 'rename' then status = @spotify.rename_playlist @auth.args[1], @auth.args[2]
                    else status = @spotify.set_playlist @auth.args[0]
                  if status
                    reply_data['text'] = 'Ok.'
                  else
                    reply_data['text'] = "I don't understand. Please consult the manual or cry for `help`."
                else
                  str = 'Currently available playlists:'
                  for key of @spotify.playlists
                    str += "\n*#{key}* (#{@spotify.playlists[key]})"
                  reply_data['text'] = str

              when 'status'
                playlistOrderPhrase = if @spotify.state.shuffle
                    " and it is being shuffled"
                  else if @spotify.state.random
                    " and tracks are being chosen at random"
                  else
                    ""

                if @spotify.is_paused()
                  reply_data['text'] = "Playback is currently *paused* on a song titled *#{@spotify.state.track.name}* from *#{@spotify.state.track.artists}*.\nYour currently selected playlist is named *#{@spotify.state.playlist.name}*#{playlistOrderPhrase}. Resume playback with `play`."
                else if !@spotify.is_playing()
                  reply_data['text'] = "Playback is currently *stopped*. You can start it again by choosing an available `list`."
                else
                  reply_data['text'] = "You are currently letting your ears feast on the beautiful tunes titled *#{@spotify.state.track.name}* from *#{@spotify.state.track.artists}*.\nYour currently selected playlist is named *#{@spotify.state.playlist.name}*#{playlistOrderPhrase}."

              when 'help'
                reply_data['text'] = "You seem lost. Here is a list of commands that are available to you:   \n   \n*Commands*\n> `play [Spotify URI]` - Starts/resumes playback if no URI is provided. If a URI is given, immediately switches to the linked track.\n> `pause` - Pauses playback at the current time.\n> `stop` - Stops playback and resets to the beginning of the current track.\n> `skip` - Skips (or shuffles) to the next track in the playlist.\n> `random` - Toggles random mode on or off.\n> `shuffle` - Toggles shuffle mode on or off.\n> `vol [up|down|0..10]` Turns the volume either up/down one notch or directly to a step between `0` (mute) and `10` (full blast). Also goes to `11`.\n> `mute` - Same as `vol 0`.\n> `unmute` - Same as `vol 0`.\n> `status` - Shows the currently playing song, playlist and whether you're in random mode or not.\n> `voteban` - Cast a vote to have the current track banned \n> `banned` - See tracks that are currently banned \n> `help` - Shows a list of commands with a short explanation.\n \n *Queue* \n \n> `queue [Spotify URI]` - Add a song to the queue\n> `queue` - See the tracks currently in the queue \n  \n*Playlists*\n> `list add <name> <Spotify URI>` - Adds a list that can later be accessed under <name>.\n> `list remove <name>` - Removes the specified list.\n> `list rename <old name> <new name>` - Renames the specified list.\n> `list <name>` - Selects the specified list and starts playback."

              when 'voteban'
                if status = @spotify.banCurrentSong(@auth.user)
                  reply_data['text'] = "#{@spotify.state.track.name} is #{status}"
                  @spotify.skip() if status == 'banned'
                else
                  reply_data['text'] = "#{@spotify.state.track.name} has *already* been banned"

              when 'banned'
                reply_data['text'] = ":rotating_light: BANNED TRACKS :rotating_light: \n#{@spotify.bannedSongs().join("\n")}"

              else
                #Just ignore and carry on
            response.serveJSON reply_data
            return
          return



module.exports = (auth, spotify, volume) ->
  handler = new SlackInterfaceRequestHandler(auth, spotify, volume)
  return handler.endpoints
