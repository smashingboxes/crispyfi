_ = require 'lodash'

class SpotifyHandler
  constructor: (options) ->
    @spotify = options.spotify
    @config = options.config
    @storage = options.storage
    @storage.initSync()

    unless @storage.getItem("banned")
      banned = [
        'spotify:track:6qR9iLM6J3u0mdGlqtldt8',
        'spotify:track:2ZCTP54O2dMSbVrdsg60to'
      ]
      @storage.setItem("banned", banned)

    unless @storage.getItem("ban_deck")
      @storage.setItem("ban_deck", {})

    @connect_timeout = null
    @connected = false

    # "playing" in this context means actually playing music or being currently paused (but NOT stopped).
    # This is an important distinction regarding the functionality of @spotify.player.resume().
    @playing = false
    @paused = false

    @state = {
      random: false
      shuffle: true
      track:
        object: null
        index: 0
        name: null
        artists: null
      playlist:
        name: null
        object: null
        shuffledTracks: null
    }

    @playlists = @storage.getItem('playlists') || {}

    @spotify.on
      ready: @spotify_connected.bind(@)
      logout: @spotify_disconnected.bind(@)
    @spotify.player.on
      endOfTrack: @skip.bind(@)

    # And off we got
    @connect()


  # Connects to Spotify.
  connect: ->
    @spotify.login @config.username, @config.password, false, false


  # Called after we have successfully connected to Spotify.
  # Clears the connect-timeout and grabs the default Playlist (or resumes playback if another playlist was set).
  spotify_connected: ->
    @connected = true
    clearTimeout @connect_timeout
    @connect_timeout = null

    # If we already have a set playlist (i.e. we were reconnecting), just keep playing.
    if @state.playlist.name?
      @play()
    # If we started fresh, get the one that we used last time
    else if last_playlist = @storage.getItem 'last_playlist'
      @set_playlist last_playlist
    # If that didn't work, try one named "default"
    else if @playlists.default?
      @set_playlist 'default'
    return


  # Called after the handler has lost its connection to Spotify.
  # Attempts to re-connect every 2.5s.
  spotify_disconnected: ->
    @connected = false
    @connect_timeout = setTimeout (() => @connect), 2500
    return


  # Called after the current playlist has been updated.
  # Simply replaces the current playlist-instance with the new one and re-bind events.
  # Player-internal state (number of tracks in the playlist, current index, etc.) is updated on @get_next_track().
  update_playlist: (err, playlist, tracks, position) ->
    if @state.playlist.object?
      # Remove event handlers from the old playlist
      @state.playlist.object.off()
    @state.playlist.object = playlist
    @state.playlist.object.on
      tracksAdded: @update_playlist.bind(this)
      tracksRemoved: @update_playlist.bind(this)
    @_shuffle_playlist(playlist) if @state.shuffle
    return


  banCurrentSong: (requesting_user) ->
    track_uri = @state.track.object.link
    return false if @is_banned(track_uri)
    banned = @storage.getItem("banned")
    if @is_bannable(track_uri, requesting_user)
      banned.push track_uri
      @storage.setItem("banned", banned)
      return 'banned'
    else
      @putOnBanDeck(track_uri, requesting_user)
      return 'on deck to be banned'

  putOnBanDeck: (track_uri, requesting_user) ->
    ban_deck = @storage.getItem("ban_deck")
    if ban_deck[requesting_user]?
      ban_deck[requesting_user].push track_uri unless ban_deck[requesting_user].indexOf(track_uri) > -1
    else
      ban_deck[requesting_user] = [track_uri]
    @storage.setItem("ban_deck", ban_deck)

  is_bannable: (track_uri, requesting_user) ->
    ban_deck = @storage.getItem("ban_deck")
    delete ban_deck[requesting_user]
    for user , bans of ban_deck
      return true if bans.indexOf(track_uri) > -1
    false

  bannedSongs: ->
    @storage.getItem("banned")

  is_banned: (uri) ->
    @storage.getItem("banned").indexOf(uri) > -1

  # Pauses playback at the current time. Can be resumed by calling @play().
  pause: ->
    @paused = true
    @spotify.player.pause()
    return

  # Stops playback. This does not just pause, but returns to the start of the current track.
  # This state can not be changed by simply calling @spotify.player.resume(), because reasons.
  # Call @play() to start playing again.
  stop: ->
    @playing = false
    @paused = false
    @spotify.player.stop()
    return


  # Plays the next track in the playlist
  skip: ->
    @play @get_next_track()
    return


  # Toggles random on and off. MAGIC!
  toggle_random: ->
    @state.random = !@state.random

    # We don't want to simultaneously be running shuffle
    # and random, so turn off shuffle if random is active
    @state.shuffle = false if @state.random

  toggle_shuffle: ->
    @state.shuffle = !@state.shuffle
    @state.track.index = 0

    if @state.shuffle
      # We don't want to simultaneously be running random
      # and shuffle, so turn off random is shuffle is active
      @state.random = false
      @_shuffle_playlist(@state.playlist.object)


  is_playing: ->
    return @playing


  is_paused: ->
    return @paused


  # Either starts the current track (or next one, if none is set) or immediately
  # plays the provided track or link.
  play: (track_or_link=null) ->
    @paused = false
    # If a track is given, immediately switch to it
    if track_or_link?
      if typeof(track_or_link) == 'string' && /track/.test(track_or_link)
        # We got a link from Slack
        # Links from Slack are encased like this: <spotify:track:1kl0Vn0FO4bbdrTbHw4IaQ>
        # So we remove everything that is neither char, number or a colon.
        new_track = @spotify.createFromLink @_sanitize_link(track_or_link)
        # If the track was somehow invalid, don't do anything
        return if !new_track?
        # We also use this to internally trigger playback of already-loaded tracks
      else if typeof(track_or_link) == 'object'
        new_track = track_or_link
        # Other input is simply disregarded
      else
        return
    # If we are already playing, simply resume
    else if @playing
      return @spotify.player.resume()
    # Last resort: We are currently neither playing not have stopped a track. So we grab the next one.
    else if !new_track
      new_track = @get_next_track()

    # We need to check whether the track has already completely loaded.
    if new_track? && new_track.isLoaded
      @_play_callback new_track
    else if new_track?
      @spotify.waitForLoaded [new_track], (track) =>
        @_play_callback new_track
    return


  # Handles the actual playback once the track object has been loaded from Spotify
  _play_callback: (track) ->
    if @is_banned(@_sanitize_link(track.link))
      @skip()
    else
      @state.track.object = track
      @state.track.name = @state.track.object.name
      @state.track.artists = @state.track.object.artists.map((artist) ->
        artist.name
      ).join ", "

      # Some tracks aren't available in our region or Spotify has lost the rights to. Newer versions
      # of node-spotify support the availability property on tracks, but with 0.6.0, we just need to
      # try to play the song and skip to the next one automatically if it fails
      try
        @spotify.player.play @state.track.object
        @playing = true
      catch
        @skip()


  # Gets the next track from the playlist. Uses modulus to easily
  # restart the playlist once it has played all the way through
  get_next_track: ->
    index = if @state.shuffle
        @_translate_shuffled_track_index(@state.track.index++ % @state.playlist.object.numTracks)
      else if @state.random
        @state.track.index = Math.floor(Math.random() * @state.playlist.object.numTracks)
      else
        @state.track.index++ % @state.playlist.object.numTracks

    @state.playlist.object.getTrack(index)

  _shuffle_playlist: (playlist) ->
    @state.playlist.shuffledTracks = _.shuffle(playlist.getTracks())

  _translate_shuffled_track_index: (shuffledIndex) ->
    track = @state.playlist.shuffledTracks[shuffledIndex]
    translatedIndex = _.findIndex(@state.playlist.object.getTracks(), link: track.link)

    return translatedIndex

  # Changes the current playlist and starts playing.
  # Since the playlist might have loaded before we can attach our callback, the actual playlist-functionality
  # is extracted to _set_playlist_callback which we call either directly or delayed once it has loaded.
  set_playlist: (name) ->
    if @playlists[name]?
      playlist = @spotify.createFromLink @playlists[name]
      if playlist && playlist.isLoaded
        @_set_playlist_callback name, playlist
      else if playlist
        @spotify.waitForLoaded [playlist], (playlist) =>
          @_set_playlist_callback name, playlist
          return true
    return true


  # The actual handling of the new playlist once it has been loaded.
  _set_playlist_callback: (name, playlist) ->
    @state.playlist.name = name

    # Update our internal state
    @update_playlist null, playlist

    @state.track.index = 0
    @play @get_next_track()

    # Also store the name as our last_playlist for the next time we start up
    @storage.setItem 'last_playlist', name
    return

  # Adds a playlist to the storage and updates our internal list
  add_playlist: (name, spotify_url) ->
    return false if !name? || !spotify_url? || !spotify_url.match(/spotify:user:.*:playlist:[0-9a-zA-Z]+/)
    spotify_url = @_sanitize_link spotify_url.match(/spotify:user:.*:playlist:[0-9a-zA-Z]+/g)[0]
    @playlists[name] = spotify_url
    @storage.setItem 'playlists', @playlists
    return true

  remove_playlist: (name) ->
    return false if !name? || !@playlists[name]?
    delete @playlists[name]
    @storage.setItem 'playlists', @playlists
    return true

  rename_playlist: (old_name, new_name) ->
    return false if !old_name? || !new_name? || !@playlists[old_name]?
    @playlists[new_name] = @playlists[old_name]
    delete @playlists[old_name]
    @storage.setItem 'playlists', @playlists
    return true


  # Removes Everything that shouldn't be in a link, especially Slack's <> encasing
  _sanitize_link: (link) ->
    link.replace /[^0-9a-zA-Z:#]/g, ''


# export things
module.exports = (options) ->
  return new SpotifyHandler(options)
