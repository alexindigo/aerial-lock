// d40 — pure topic normalization / matching / playlist selection.
// No imports, no I/O: unit-testable with plain node. Matching is on
// lowercased WHOLE words; any declared topic matching a clip's words is
// enough (OR semantics). No stemming, embeddings, semantic categories,
// ranking, or network.

function normalizeWords(s) {
    if (typeof s !== "string" || s.length === 0)
        return []
    var parts = s.toLowerCase().split(/[^a-z0-9]+/)
    var out = []
    for (var i = 0; i < parts.length; i++)
        if (parts[i].length > 0)
            out.push(parts[i])
    return out
}

function normalizeTopics(topics) {
    var out = []
    if (!topics || !topics.length)
        return out
    for (var i = 0; i < topics.length; i++) {
        var ws = normalizeWords(topics[i])
        for (var j = 0; j < ws.length; j++)
            if (out.indexOf(ws[j]) === -1)
                out.push(ws[j])
    }
    return out
}

function clipMatches(matchText, topicWords) {
    var words = normalizeWords(matchText)
    for (var t = 0; t < topicWords.length; t++) {
        if (words.indexOf(topicWords[t]) !== -1)
            return true
    }
    return false
}

// inventory: [{path: "...", matchText: "..."}] in source order.
// Returns the matching subset's paths in ORIGINAL order, or the full pool
// when topics are empty or nothing matches.
function selectPlaylist(inventory, topics) {
    var all = []
    for (var i = 0; i < inventory.length; i++)
        all.push(inventory[i].path)

    var topicWords = normalizeTopics(topics)
    if (topicWords.length === 0)
        return all

    var matching = []
    for (var j = 0; j < inventory.length; j++) {
        if (clipMatches(inventory[j].matchText, topicWords))
            matching.push(inventory[j].path)
    }
    return matching.length > 0 ? matching : all
}
