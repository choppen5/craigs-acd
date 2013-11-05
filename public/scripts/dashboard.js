Dashboard = {
  add: function(number) {
    $.getJSON("/dashboard/add", {"number":number}, function(result) {
      window.location.reload();
    });
    return false;
  },

  remove: function(name) {
    $.getJSON("/dashboard/remove", {"name":name}, function(result) {
      window.location.reload();
    });
    return false;
  },

  save: function(name) {
    $.getJSON("/dashboard/save", {"name":name}, function(result) {
      alert('saved');
    });
    return false;
  },

  restore: function(name) {
    $.getJSON("/dashboard/restore", {"name":name}, function(result) {
      window.location.reload();
    });
    return false;
  },

}

