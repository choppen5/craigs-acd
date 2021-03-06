// Page loaded
$(function() {

  // ** Application container ** //
  window.SP = {}

  // Global state
  SP.state = {};
  SP.state.callNumber = null;
  SP.username = "default_client";
  SP.agent_number = "";


  SP.functions = {};


  SP.functions.getSFDCUserInfo = function () {

    var callback = function (response) {
      if (response.result) {
        console.log("result = " + response.result);
        var useresult = response.result;
        useresult = useresult.replace("@", "AT");
        useresult = useresult.replace(".", "DOT");
        SP.username = useresult;

      } else {
        console.log("error = " + response.error);
      }

      //get existing info for this guy

      SP.functions.startWebSocket();
      SP.functions.updateStatus(); //get status if he's already logged in


    };

    //how  can we tell if sforce works before calling this?
    sforce.interaction.runApex('UserInfo', 'getUserName', '' ,callback);

  }


  //1. run sfdc code



  // ** UI Widgets ** //

  // Hook up numpad to input field
  $("#agent-number-entry input").bind('keyup',function(e){
    var pressed;
    if(navigator.appName == "Netscape") pressed = e.which;
    if(navigator.appVersion.indexOf("MSIE") != -1) pressed = event.keyCode;

    if(pressed == 13) SP.functions.ready();
  });

  // Hook up numpad to input field
  $("div.number").bind('click',function(){
    $("#number-entry > input").val($("#number-entry > input").val()+$(this).attr('Value'));
  });

  // Hide caller info
  SP.functions.hideCallData = function() {
    $("#call-data").hide();
  }
  SP.functions.hideCallData();

  // Show caller info
  SP.functions.showCallData = function(callData) {
    $("#call-data > ul").hide();
    $(".caller-name").text(callData.callerName);
    $(".caller-number").text(callData.callerNumber);
    $(".caller-queue").text(callData.callerQueue);
    $(".caller-message").text(callData.callerMessage);

    if (callData.callerName) {
      $("#call-data > ul.name").show();
    }

    if (callData.callerNumber) {
      $("#call-data > ul.phone_number").show();
    }

    if (callData.callerQueue) {
      $("#call-data > ul.queue").show();
    }

    if (callData.callerMessage) {
      $("#call-data > ul.message").show();
    }

    $("#call-data").slideDown(400);
  }

  // Attach answer button to an incoming connection object
  SP.functions.attachAnswerButton = function(conn) {
    $("#action-buttons > button.answer").click(function() {
      conn.accept();
    }).removeClass('inactive').addClass("active");
  }

  SP.functions.detachAnswerButton = function() {
    $("#action-buttons > button.answer").unbind().removeClass('active').addClass("inactive");
  }

  SP.functions.updateAgentStatusText = function(statusCategory, statusText) {

    if (statusCategory == "missed") {
      $("#agent-status").removeClass();
      $("#agent-status").addClass("not-ready");
    }

    if (statusCategory == "ready") {
      $("#agent-status").removeClass();
      $("#agent-status").addClass("ready");
    }

    if (statusCategory == "notReady") {
      $("#agent-status").removeClass();
      $("#agent-status").addClass("not-ready");
    }

    if (statusCategory == "onCall") {
      $("#agent-status").removeClass();
      $("#agent-status").addClass("on-call");
    }

    $("#agent-status > p").text(statusText);
  }

  // Call button will make an outbound call (click to dial) to the number entered
  $("#action-buttons > button.call").click( function( ) {
    //alert("TODO: Call new /clicktodial action");
    var customernumber = $("#number-entry > input").val();
    var agent_number = $("#agent-number-entry input").val();

    var params = {"customernumber": customernumber, "agentnumber": agent_number, "agent": SP.username};

    $.get("/clicktodial", params, function(data) {
      SP.functions.updateAgentStatusText("onCall", "Calling: " + customernumber);
    });

  });

  // Wire the ready / not ready buttons up to the server-side status change functions
  $("#agent-status-controls > button.ready").click( function( ) {
    SP.functions.ready();
  });

  $("#agent-status-controls > button.not-ready").click( function( ) {
    SP.functions.notReady();
  });

    $("#agent-status-controls > button.userinfo").click( function( ) {
    SP.functions.getSFDCUserInfo();
  });



  // ** Twilio Client Stuff ** //

  // get username, generate token, set up device with token. callbacks bitch.
  sforce.interaction.cti.disableClickToDial(); //start off disabled 

  SP.functions.getSFDCUserInfo();
  
  //sforce.interaction.cti.onClickToDial(startCall);


  // No longer need twilio stuff?

  //   Twilio.Device.ready(function (device) {
  //     sforce.interaction.cti.enableClickToDial();
  //     sforce.interaction.cti.onClickToDial(startCall);
  //     SP.functions.ready();
  //   });

  //   Twilio.Device.offline(function (device) {
  //     //make a new status call.. something like.. disconnected instead of notReady ?
  //     sforce.interaction.cti.disableClickToDial();
  //     SP.functions.notReady();
  //     SP.functions.hideCallData();
  //   });


  //   /* Report any errors on the screen */
  //   Twilio.Device.error(function (error) {
  //       SP.functions.updateAgentStatusText("ready", error.message);
  //       SP.functions.hideCallData();
  //   });

  //   /* Log a message when a call disconnects. */
  //   Twilio.Device.disconnect(function (conn) {
  //     SP.functions.updateAgentStatusText("ready", "Call ended");

  //     sforce.interaction.getPageInfo(saveLog);

  //     SP.state.callNumber = null;

  //     // deactivate answer button
  //     SP.functions.detachAnswerButton();

  //     // return to waiting state
  //     SP.functions.hideCallData();
  //     SP.functions.ready();
  //   });

  //   Twilio.Device.connect(function (conn) {

  //     console.dir(conn);
  //     var  status = "";

  //     var callNum = null;
  //     if (conn.parameters.From) {
  //       callNum = conn.parameters.From;
  //       status = "Call From: " + callNum;
  //     } else {
  //       status = "Outbound call";

  //     }


  //     SP.functions.updateAgentStatusText("onCall", status);
  //     SP.functions.detachAnswerButton();

  //     //send status info
  //     $.get("/track", { "from":SP.username, "status":"OnCall" }, function(data) {

  //     });

  //   });


  SP.functions.screenPop = function(options) {

    // Update agent status
    sforce.interaction.setVisible(true);  //pop up CTI console

    var from = options["From"];



    SP.functions.updateAgentStatusText("onCall", ("Call from: " + from))

    var inboundnum = cleanInboundTwilioNumber(from);
    var result = "";

    var name = '';

    sforce.interaction.searchAndScreenPop(inboundnum, 'con10=' + inboundnum + '&name_firstcon2=' + name,'inbound');

  }


  SP.functions.startWebSocket = function() {
    // ** Agent Presence Stuff ** //
    console.log(".startWebSocket...");

    var wsaddress = 'wss://' + window.location.host  + "/websocket?clientname=" + SP.username
    // Temp > hit localhost
    //     var wsaddress = 'ws://' + window.location.host  + "/websocket?clientname=" + SP.username

    var ws = new WebSocket(wsaddress);
    ws.onopen    = function()  { console.log('websocket opened'); };
    ws.onclose   = SP.functions.onWebsocketClose;

    // Socket message from server, so screen pop or update status...

    ws.onmessage = function(m) {
      console.log('message from server: ' + m.data);

      var result = JSON.parse(m.data);

      if(result['do'] == 'screenpop'){   // If call, do screen pop
        SP.functions.screenPop(result);
      }else if(result['do'] == 'paint'){   // If status message, just update
        SP.functions.paint(result);
      }else{   // If status message, just update
        $("#team-status > .queues-status").text("Call Queue:  " + result.queuesize);
        $("#team-status > .agents-status").text("Ready Agents:  " + result.readyagents);
      }
    };
  }

  SP.functions.onWebsocketClose = function() {
    window.setTimeout(function(){
      $("#agent-status").addClass('interrupted').find('p').text('disconnected');
    }, 3000);
    console.log('websocket closed');
  }

  // Set server-side status to ready / not-ready
  SP.functions.notReady = function() {
    $.get("/track", { "from":SP.username, "status":"NotReady", "agent_number": SP.agent_number }, function(data) {
      SP.functions.updateStatus();
    });
  }

  SP.functions.ready = function() {
    // Show alert if they haven't entered a phone number
    var agent_number = $("#agent-number-entry input").val();
    if(agent_number == "") {
      alert("Enter your number in the 'your number' field and click 'Ready'.");
      return false;
    } else {
      SP.agent_number = agent_number;
    }

    $.get("/track", { "agent_number":agent_number, "from":SP.username, "status":"Ready" }, function(data) {
      SP.functions.updateStatus();
    });
  }


  // Check the status on the server and update the agent status dialog accordingly
  SP.functions.updateStatus = function() {
    $.getJSON("/status", { "from":SP.username}, function(result) {
      console.log("getting status info = " + result);

      if (result.status == "NotReady") {
        SP.functions.updateAgentStatusText("notReady", "Not Ready");
      }

      if (result.status == "Ready") {
        SP.functions.updateAgentStatusText("ready", "Ready");
      }

      if (result.status == "Inbound") {
        var from = result.inbound_number;
        SP.functions.updateAgentStatusText("onCall", "Call from: " + from);
      }

      if (result.status == "Missed") {
        SP.functions.updateAgentStatusText("missed", "Missed");
      }

      //show what the server thinks your number is, as that is what counts
      if (result.phone) {
        $("#agent-number-entry input").val(result.phone);
        SP.agent_number = result.phone;
      } else {
        $("#agent-number-entry input").val(SP.agent_number);
      }

      if (SP.agent_number) {
        //only enable click2dial if phone number has been set
        sforce.interaction.cti.enableClickToDial();
        sforce.interaction.cti.onClickToDial(startCall);
      }

    });

  }


  SP.functions.paint = function(result) {

    if (result.agent_number_entry) {
      $("#agent-number-entry input").val(result['agent_number_entry']);
    }

    //not all websockets have a status message
    if (result.status) {
      if (result.status == "Ready") {
          SP.functions.updateAgentStatusText("ready", "Ready");
      } else {
          SP.functions.updateAgentStatusText("notReady", result.status);
      }
    }

  }

  /******** GENERAL FUNCTIONS for SFDC  ***********************/

  function cleanInboundTwilioNumber(number) {
    //twilio inabound calls are passed with +1 (number). SFDC only stores
    return number.replace('+1','');
  }

  function cleanFormatting(number) {
    //changes a SFDC formatted US number, which would be 415-555-1212
    return number.replace(' ','').replace('-','').replace('(','').replace(')','').replace('+','');
  }

  function startCall(response) {
    var result = JSON.parse(response.result);
    var cleanednumber = cleanFormatting(result.number);

    SP.functions.updateAgentStatusText("onCall", ("Calling: " + cleanednumber))

    var params = {"customernumber": cleanednumber, "agentnumber": SP.agent_number, "agent": SP.username};

    $.get("/clicktodial", params, function(data) {
      SP.functions.updateAgentStatusText("onCall", "Calling: " + cleanednumber);
    });

  }

  function saveLog(response) {

    console.log("saving log result, response:");
    var result = JSON.parse(response.result);

    console.log(response.result);

    var timeStamp = new Date().toString();
    timeStamp = timeStamp.substring(0, timeStamp.lastIndexOf(':') + 3);
    var currentDate = new Date();
    var currentDay = currentDate.getDate();
    var currentMonth = currentDate.getMonth()+1;
    var currentYear = currentDate.getFullYear();
    var dueDate = currentYear + '-' + currentMonth + '-' + currentDay;
    var saveParams = 'Subject=' + 'Call on ' + timeStamp;

    saveParams += '&Status=completed';
    saveParams += '&CallType=' + 'Inbound';
    saveParams += '&Activitydate=' + dueDate;
    saveParams += '&CallObject=' + currentDate.getTime();
    saveParams += '&Phone=' + SP.state.callNumber;  //we need to get this from.. somewhere
    saveParams += '&Description=' + "test description";

    console.log("About to parse  result..");

    var result = JSON.parse(response.result);
    if(result.objectId.substr(0,3) == '003') {
        saveParams += '&whoId=' + result.objectId;
    } else {
        saveParams += '&whatId=' + result.objectId;
    }

    console.log("save params = " + saveParams);
    sforce.interaction.saveLog('Task', saveParams);
  }






});
