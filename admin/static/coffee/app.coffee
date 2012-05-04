
# This file contains all the good stuff we do to set up the
# application. We should refactor this at some point, but I'm leaving
# it as is for now.

modal_registry = []
clear_modals = ->
    modal.hide_modal() for modal in modal_registry
    modal_registry = []
register_modal = (modal) -> modal_registry.push(modal)

updateInterval = 5000

declare_client_connected = ->
    window.connection_status.set({client_disconnected: false})
    clearTimeout(window.apply_diffs_timer)
    window.apply_diffs_timer = setTimeout (-> window.connection_status.set({client_disconnected: true})), 2 * updateInterval

apply_to_collection = (collection, collection_data) ->
    for id, data of collection_data
        if data
            if collection.get(id)
                collection.get(id).set(data)
            else
                data.id = id
                collection.add(new collection.model(data))
        else
            if collection.get(id)
                collection.remove(id)

add_protocol_tag = (data, tag) ->
    f = (unused,id) ->
        if (data[id])
            data[id].protocol = tag
    _.each(data, f)
    return data

reset_collections = () ->
    namespaces.reset()
    datacenters.reset()
    machines.reset()
    issues.reset()
    directory.reset()

# Process updates from the server and apply the diffs to our view of the data. Used by our version of Backbone.sync and POST / PUT responses for form actions
apply_diffs = (updates) ->
    declare_client_connected()

    if (not connection_status.get('contact_machine_id'))
        connection_status.set('contact_machine_id', updates["me"])
    else
        if (updates["me"] != connection_status.get('contact_machine_id'))
            reset_collections()
            connection_status.set('contact_machine_id', updates["me"])

    for collection_id, collection_data of updates
        switch collection_id
            when 'dummy_namespaces'
                apply_to_collection(namespaces, add_protocol_tag(collection_data, "dummy"))
            when 'memcached_namespaces'
                apply_to_collection(namespaces, add_protocol_tag(collection_data, "memcached"))
            when 'datacenters'
                apply_to_collection(datacenters, collection_data)
            when 'machines'
                apply_to_collection(machines, collection_data)
            when 'me' then continue
            else
                console.log "Unhandled element update: " + updates
    return

set_issues = (issue_data_from_server) -> issues.reset(issue_data_from_server)

set_progress = (progress_data_from_server) ->
    # Convert progress representation from RethinkDB into backbone friendly one
    _pl = []
    for key, value of progress_data_from_server
        value['id'] = key
        _pl.push(value)
    progress_list.reset(_pl)

set_directory = (attributes_from_server) ->
    # Convert directory representation from RethinkDB into backbone friendly one
    dir_machines = []
    for key, value of attributes_from_server
        value['id'] = key
        dir_machines[dir_machines.length] = value
    directory.reset(dir_machines)

set_last_seen = (last_seen) ->
    # Expand machines model with this data
    for machine_uuid, timestamp of last_seen
        _m = machines.get machine_uuid
        if _m
            _m.set('last_seen', timestamp)

set_log_entries = (log_data_from_server) ->
    all_log_entries = []
    for machine_uuid, log_entries of log_data_from_server
        _m_collection = new LogEntries
        for json in log_entries
            entry = new LogEntry json
            entry.set('machine_uuid',machine_uuid)
            _m_collection.add entry
            all_log_entries.push entry

        _m = machines.get(machine_uuid)
        if _m?
            machines.get(machine_uuid).set('log_entries', _m_collection)

    recent_log_entries.reset(all_log_entries)

$ ->
    bind_dev_tools()

    # Initializing the Backbone.js app
    window.datacenters = new Datacenters
    window.namespaces = new Namespaces
    window.machines = new Machines
    window.issues = new Issues
    window.progress_list = new ProgressList
    window.directory = new Directory
    window.recent_log_entries = new LogEntries
    window.connection_status = new ConnectionStatus

    window.last_update_tstamp = 0

    # Load the data bootstrapped from the HTML template
    # reset_collections()
    reset_token()

    # A helper function to collect data from all of our shitty
    # routes. TODO: somebody fix this in the server for heaven's
    # sakes!!!
    #   - an optional callback can be provided. Currently this callback will only be called after the /ajax route (metadata) is collected
    collect_server_data = (optional_callback) =>
        $.getJSON('/ajax', (updates) ->
            apply_diffs(updates)
            optional_callback() if optional_callback
        )
        $.getJSON('/ajax/issues', set_issues)
        $.getJSON('/ajax/progress', set_progress)
        $.getJSON('/ajax/directory', set_directory)
        $.getJSON('/ajax/last_seen', set_last_seen)
        $.getJSON('/ajax/log/_?max_length=10', set_log_entries)

    # Override the default Backbone.sync behavior to allow reading diffs
    legacy_sync = Backbone.sync
    Backbone.sync = (method, model, success, error) ->
        if method is 'read'
            collect_server_data()
        else
            legacy_sync method, model, success, error


    # This object is for global events whose relevant data may not be available yet. Example include:
    #   - the router is unavailable when first initializing
    #   - machines, namespaces, and datacenters collections are unavailable when first initializing
    window.app_events =
        triggered_events: {}
    _.extend(app_events, Backbone.Events)
    # Count the number of times any particular event has been called
    app_events.on 'all', (event) ->
        triggered = app_events.triggered_events

        if not triggered[event]?
            triggered[event] = 1
        else
            triggered[event]+=1

    # Create the app
    window.app = new BackboneCluster

    # Signal that the router is ready to be bound to
    app_events.trigger('router_ready')

    # Now that we're all bound, start routing
    Backbone.history.start()

    setInterval (-> Backbone.sync 'read', null), updateInterval
    declare_client_connected()

    # Provide one optional callback that will indicate when collections are fully populated
    collect_server_data( -> app_events.trigger('collections_ready'))

    # Set up common DOM behavior
    $('.modal').modal
        backdrop: true
        keyboard: true