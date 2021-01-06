namespace Frida.Droidy {
	public class DeviceTracker : Object {
		public signal void device_attached (string serial, string name);
		public signal void device_detached (string serial);

		private Client? client;
		private Gee.HashMap<string, DeviceInfo> devices = new Gee.HashMap<string, DeviceInfo> ();
		private Cancellable io_cancellable = new Cancellable ();

		public async void open (Cancellable? cancellable = null) throws Error, IOError {
			client = yield Client.open (cancellable);
			client.message.connect (on_message);

			try {
				try {
					var devices_encoded = yield client.request_data ("host:track-devices-l", cancellable);
					yield update_devices (devices_encoded, cancellable);
				} catch (Error.NOT_SUPPORTED e) {
					client.message.disconnect (on_message);
					client = null;

					client = yield Client.open (cancellable);
					var devices_encoded = yield client.request_data ("host:track-devices", cancellable);
					yield update_devices (devices_encoded, cancellable);
				}
			} catch (GLib.Error e) {
				if (client != null)
					yield client.close (cancellable);
			}
		}

		public async void close (Cancellable? cancellable = null) throws IOError {
			if (client == null)
				return;

			io_cancellable.cancel ();

			yield client.close (cancellable);
		}

		private void on_message (string devices_encoded) {
			update_devices.begin (devices_encoded, io_cancellable);
		}

		private async void update_devices (string devices_encoded, Cancellable? cancellable) throws IOError {
			var detached = new Gee.ArrayList<DeviceInfo> ();
			var attached = new Gee.ArrayList<DeviceInfo> ();

			var current = new Gee.HashMap<string, string?> ();
			foreach (var line in devices_encoded.split ("\n")) {
				MatchInfo info;
				if (!/^(\S+)\s+(\S+)( (.+))?$/m.match (line, 0, out info)) {
					continue;
				}

				string serial = info.fetch (1);

				string type = info.fetch (2);
				if (type != "device")
					continue;

				string? name = null;
				if (info.get_match_count () == 5) {
					string[] details = info.fetch (4).split (" ");
					foreach (unowned string pair in details) {
						if (pair.has_prefix ("model:")) {
							name = pair.substring (6).replace ("_", " ");
							break;
						}
					}
				}

				current[serial] = name;
			}
			foreach (var entry in devices.entries) {
				var serial = entry.key;
				var info = entry.value;
				if (!current.has_key (serial))
					detached.add (info);
			}
			foreach (var entry in current.entries) {
				unowned string serial = entry.key;
				if (!devices.has_key (serial))
					attached.add (new DeviceInfo (serial, entry.value));
			}

			foreach (var info in detached)
				devices.unset (info.serial);
			foreach (var info in attached)
				devices[info.serial] = info;

			foreach (var info in detached) {
				if (info.announced)
					device_detached (info.serial);
			}
			foreach (var info in attached)
				yield announce_device (info, cancellable);
		}

		private async void announce_device (DeviceInfo info, Cancellable? cancellable) throws IOError {
			var serial = info.serial;

			uint port = 0;
			serial.scanf ("emulator-%u", out port);
			if (port != 0) {
				info.name = "Android Emulator %u".printf (port);
			} else if (info.name == null) {
				try {
					info.name = yield detect_name (info.serial, cancellable);
				} catch (Error e) {
					info.name = "Android Device";
				}
			}

			var still_attached = devices.has_key (info.serial);
			if (still_attached) {
				info.announced = true;
				device_attached (info.serial, info.name);
			}
		}

		private async string detect_name (string device_serial, Cancellable? cancellable) throws Error, IOError {
			var output = yield ShellCommand.run ("getprop ro.product.model", device_serial, cancellable);
			return output.chomp ();
		}

		private class DeviceInfo {
			public string serial {
				get;
				private set;
			}

			public string? name {
				get;
				set;
			}

			public bool announced {
				get;
				set;
			}

			public DeviceInfo (string serial, string? name) {
				this.serial = serial;
				this.name = name;
			}
		}
	}

	namespace ShellCommand {
		private const int CHUNK_SIZE = 4096;

		public static async string run (string command, string device_serial, Cancellable? cancellable = null) throws Error, IOError {
			var client = yield Client.open (cancellable);

			try {
				yield client.request ("host:transport:" + device_serial, cancellable);
				yield client.request_protocol_change ("shell:" + command, cancellable);

				var input = client.stream.get_input_stream ();
				var buf = new uint8[CHUNK_SIZE];
				var offset = 0;
				while (true) {
					var capacity = buf.length - offset;
					if (capacity < CHUNK_SIZE)
						buf.resize (buf.length + CHUNK_SIZE - capacity);

					ssize_t n;
					try {
						n = yield input.read_async (buf[offset:buf.length - 1], Priority.DEFAULT, cancellable);
					} catch (IOError e) {
						throw new Error.TRANSPORT ("%s", e.message);
					}

					if (n == 0)
						break;

					offset += (int) n;
				}
				buf[offset] = '\0';

				char * chars = buf;
				return (string) chars;
			} finally {
				client.close.begin (cancellable);
			}
		}
	}

	public class Client : Object {
		public signal void message (string payload);

		public IOStream stream {
			get;
			construct;
		}
		private InputStream input;
		private OutputStream output;
		private Cancellable io_cancellable = new Cancellable ();

		protected bool is_processing_messages;
		private Gee.ArrayQueue<PendingResponse> pending_responses = new Gee.ArrayQueue<PendingResponse> ();

		public enum RequestType {
			COMMAND,
			SUBCOMMAND,
			DATA,
			PROTOCOL_CHANGE
		}

		private const uint16 ADB_SERVER_PORT = 5037;
		private const uint16 MAX_MESSAGE_LENGTH = 1024;
		private const size_t MAX_DATA_SIZE = 65536;

		public static async Client open (Cancellable? cancellable = null) throws Error, IOError {
			IOStream stream;
			try {
				var client = new SocketClient ();
				var connection = yield client.connect_async (new NetworkAddress.loopback (ADB_SERVER_PORT), cancellable);

				Tcp.enable_nodelay (connection.socket);

				stream = connection;
			} catch (GLib.Error e) {
				throw new Error.NOT_SUPPORTED ("%s", e.message);
			}

			return new Client (stream);
		}

		public Client (IOStream stream) {
			Object (stream: stream);
		}

		construct {
			input = stream.get_input_stream ();
			output = stream.get_output_stream ();

			is_processing_messages = true;

			process_incoming_messages.begin ();
		}

		public async void close (Cancellable? cancellable = null) throws IOError {
			if (is_processing_messages) {
				is_processing_messages = false;

				io_cancellable.cancel ();

				var source = new IdleSource ();
				source.set_priority (Priority.LOW);
				source.set_callback (close.callback);
				source.attach (MainContext.get_thread_default ());
				yield;
			}

			try {
				yield this.stream.close_async (Priority.DEFAULT, cancellable);
			} catch (GLib.Error e) {
				if (e is IOError.CANCELLED)
					throw (IOError) e;
			}
		}

		public static async void push (string device_serial, InputStream content, string remote_path, Cancellable? cancellable = null) throws Error, IOError {
			int mode = 0100666;
			var timestamp = new DateTime.now_local ();

			try {
				var c = yield open (cancellable);
				yield c.request ("host:transport:" + device_serial, cancellable);
				yield c.request ("sync:", cancellable);

				var cmd_buf = new MemoryOutputStream.resizable ();
				var cmd = new DataOutputStream (cmd_buf);
				cmd.byte_order = LITTLE_ENDIAN;

				string raw_mode = "%d".printf (mode);

				cmd.put_string ("SEND");
				cmd.put_uint32 (remote_path.length + 1 + raw_mode.length);
				cmd.put_string (remote_path);
				cmd.put_string (",");
				cmd.put_string (raw_mode);

				while (true) {
					Bytes chunk = yield content.read_bytes_async (MAX_DATA_SIZE, Priority.DEFAULT, cancellable);
					size_t size = chunk.get_size ();
					if (size == 0)
						break;

					cmd.put_string ("DATA");
					cmd.put_uint32 ((uint32) size);
					cmd.write_bytes (chunk);

					unowned uint8[] raw_chunk_data = cmd_buf.get_data ();
					unowned uint8[] chunk_data = raw_chunk_data[0:cmd_buf.data_size];
					size_t bytes_written;
					yield c.output.write_all_async (chunk_data, Priority.DEFAULT, cancellable, out bytes_written);

					cmd_buf.close ();
					cmd_buf = new MemoryOutputStream.resizable ();
					cmd = new DataOutputStream (cmd_buf);
					cmd.byte_order = LITTLE_ENDIAN;
				}

				cmd.put_string ("DONE");
				cmd.put_uint64 (timestamp.to_unix ());

				cmd.put_string ("QUIT");
				cmd.put_uint32 (0);

				cmd_buf.close ();
				yield c.raw_request (cmd_buf.steal_as_bytes (), SUBCOMMAND, cancellable);
			} catch (GLib.Error e) {
				throw new Error.TRANSPORT ("%s", e.message);
			}
		}

		public static async string jdwp (string device_serial, Cancellable? cancellable = null) throws Error, IOError {
			var c = yield open (cancellable);
			yield c.request ("host:transport:" + device_serial, cancellable);
			var list_pids = yield c.request_data ("jdwp", cancellable);

			return list_pids;
		}

		public async void request (string message, Cancellable? cancellable = null) throws Error, IOError {
			yield request_with_type (message, RequestType.COMMAND, cancellable);
		}

		public async string request_data (string message, Cancellable? cancellable = null) throws Error, IOError {
			return yield request_with_type (message, RequestType.DATA, cancellable);
		}

		public async void request_protocol_change (string message, Cancellable? cancellable = null) throws Error, IOError {
			yield request_with_type (message, RequestType.PROTOCOL_CHANGE, cancellable);
		}

		private async string? request_with_type (string message, RequestType request_type, Cancellable? cancellable)
				throws Error, IOError {
			Bytes response_bytes = yield raw_request (new Bytes (message.data), request_type, cancellable);
			if (response_bytes == null)
				return null;
			return (string) Bytes.unref_to_data ((owned) response_bytes);
		}

		public async Bytes? raw_request (Bytes message, RequestType request_type, Cancellable? cancellable) throws Error, IOError {
			bool waiting = false;

			var pending = new PendingResponse (request_type, () => {
				if (waiting)
					raw_request.callback ();
			});
			pending_responses.offer_tail (pending);

			var cancel_source = new CancellableSource (cancellable);
			cancel_source.set_callback (() => {
				pending.complete_with_error (new IOError.CANCELLED ("Operation was cancelled"));
				return false;
			});
			cancel_source.attach (MainContext.get_thread_default ());

			try {
				size_t bytes_written;
				try {
					if (request_type == SUBCOMMAND) {
						yield output.write_all_async (message.get_data (), Priority.DEFAULT, cancellable, out bytes_written);
					} else {
						var message_size = message.get_size ();
						var message_buf = new uint8[4 + message_size];
						var length_str = "%04x".printf (message.length);
						Memory.copy (message_buf, length_str, 4);
						Memory.copy ((uint8 *) message_buf + 4, message.get_data (), message_size);

						yield output.write_all_async (message_buf, Priority.DEFAULT, cancellable, out bytes_written);
					}
				} catch (GLib.Error e) {
					throw new Error.TRANSPORT ("Unable to write message: %s", e.message);
				}

				if (!pending.completed) {
					waiting = true;
					yield;
					waiting = false;
				}
			} finally {
				cancel_source.destroy ();
			}

			cancellable.set_error_if_cancelled ();

			if (pending.error != null)
				throw_api_error (pending.error);

			return pending.result;
		}

		private async void process_incoming_messages () {
			while (is_processing_messages) {
				try {
					var command_or_length = yield read_fixed_string (4);
					switch (command_or_length) {
						case "OKAY":
						case "FAIL":
							var pending = pending_responses.poll_head ();
							if (pending != null) {
								var success = command_or_length == "OKAY";
								if (success) {
									Bytes? result;
									if (pending.request_type == RequestType.DATA)
										result = yield read_bytes ();
									else
										result = null;
									pending.complete_with_result (result);

									if (pending.request_type == RequestType.PROTOCOL_CHANGE) {
										is_processing_messages = false;
										return;
									}
								} else {
									var error_message = yield read_string ();
									pending.complete_with_error (
										new Error.NOT_SUPPORTED (error_message));
								}
							} else {
								throw new Error.PROTOCOL ("Reply to unknown request");
							}
							break;
						case "SYNC":
						case "CNXN":
						case "AUTH":
						case "OPEN":
						case "CLSE":
						case "WRTE":
							throw new Error.PROTOCOL ("Unexpected command");

						default:
							var length = parse_length (command_or_length);
							var payload = yield read_fixed_string (length);
							message (payload);
							break;
					}
				} catch (Error e) {
					foreach (var pending_response in pending_responses)
						pending_response.complete_with_error (e);
					is_processing_messages = false;
				}
			}
		}

		private async string read_string () throws Error {
			var length_str = yield read_fixed_string (4);
			var length = parse_length (length_str);
			return yield read_fixed_string (length);
		}

		private async string read_fixed_string (size_t length) throws Error {
			var buf = new uint8[length + 1];
			size_t bytes_read;
			try {
				yield input.read_all_async (buf[0:length], Priority.DEFAULT, io_cancellable, out bytes_read);
			} catch (GLib.Error e) {
				throw new Error.TRANSPORT ("Unable to read string: %s", e.message);
			}
			if (bytes_read != length)
				throw new Error.TRANSPORT ("Unable to read string");
			buf[length] = '\0';
			char * chars = buf;
			return (string) chars;
		}

		private async Bytes read_bytes () throws Error {
			var length_str = yield read_fixed_string (4);
			var length = parse_length (length_str);
			var buf = new uint8[length + 1];
			size_t bytes_read;
			try {
				yield input.read_all_async (buf[0:length], Priority.DEFAULT, io_cancellable, out bytes_read);
			} catch (GLib.Error e) {
				throw new Error.TRANSPORT ("Unable to read: %s", e.message);
			}
			if (bytes_read != length)
				throw new Error.TRANSPORT ("Unable to read");
			buf.length = (int) length;
			return new Bytes.take ((owned) buf);
		}

		private size_t parse_length (string str) throws Error {
			int length = 0;
			str.scanf ("%04x", out length);
			if (length < 0 || length > MAX_MESSAGE_LENGTH)
				throw new Error.PROTOCOL ("Invalid message length");
			return length;
		}

		private class PendingResponse {
			public delegate void CompletionHandler ();
			private CompletionHandler handler;

			public RequestType request_type {
				get;
				private set;
			}

			public bool completed {
				get {
					return result != null || error != null;
				}
			}

			public Bytes? result {
				get;
				private set;
			}

			public GLib.Error? error {
				get;
				private set;
			}

			public PendingResponse (RequestType request_type, owned CompletionHandler handler) {
				this.request_type = request_type;
				this.handler = (owned) handler;
			}

			public void complete_with_result (Bytes? result) {
				if (handler == null)
					return;
				this.result = result;
				handler ();
				handler = null;
			}

			public void complete_with_error (GLib.Error error) {
				if (handler == null)
					return;
				this.error = error;
				handler ();
				handler = null;
			}
		}
	}
}
