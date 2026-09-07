module Heucristic
  module Protocol
    module Framing
      extend self

      record EndOfStream
      record Malformed, reason : String
      record Disconnected, reason : String

      CONTENT_LENGTH = "Content-Length:"

      def read(io : IO) : String | EndOfStream | Malformed
        length = read_headers(io)
        return length unless length.is_a?(Int32)

        body = Bytes.new(length)
        filled = read_body(io, body)
        return filled unless filled.is_a?(Bytes)

        String.new(filled)
      end

      def write(io : IO, body : String) : Disconnected?
        io << CONTENT_LENGTH << ' ' << body.bytesize << "\r\n\r\n" << body
        io.flush
        nil
      rescue error : IO::Error
        Disconnected.new(error.message || error.class.name)
      end

      private def read_headers(io : IO) : Int32 | EndOfStream | Malformed
        length : Int32? = nil

        loop do
          line = read_line(io)
          return line unless line.is_a?(String)
          break if line.empty?

          next unless (value = line.lchop?(CONTENT_LENGTH))
          parsed = value.strip.to_i32?
          return Malformed.new("unparseable Content-Length #{value.strip.inspect}") unless parsed
          length = parsed
        end

        length || Malformed.new("headers without Content-Length")
      end

      private def read_line(io : IO) : String | EndOfStream
        io.gets(chomp: true) || EndOfStream.new
      rescue IO::Error
        EndOfStream.new
      end

      private def read_body(io : IO, body : Bytes) : Bytes | EndOfStream
        io.read_fully?(body) ? body : EndOfStream.new
      rescue IO::Error
        EndOfStream.new
      end
    end
  end
end
