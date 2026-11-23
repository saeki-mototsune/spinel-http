require "spinel-http/query"
require "spinel-http/uploaded_file"

# What Request needs of multipart whether or not the parser is loaded: the
# faults, the parsed form, and the parser slot's null default. The parser
# itself is spinel-http/multipart, which installs itself with
# `Request.multipart_parser=` when required.
module SpinelHttp
  # The body of a multipart/form-data request is not well formed (no or an
  # invalid boundary, a part without its headers or its closing delimiter,
  # a Content-Disposition that is not form-data, a bad name, ...). A client
  # fault: ClientError answers 400 (listed in CLIENT_FAULTS). The four
  # Multipart classes are QueryInvalid subclasses.
  # @api public
  class MultipartMalformed < QueryInvalid
  end

  # More parts than the installed limit ({Multipart.max_parts}).
  # @api public
  class MultipartTooManyParts < QueryInvalid
  end

  # A file part past {Multipart.max_upload_bytes}, or the text parts together
  # past Multipart::MAX_TEXT_BYTES.
  # @api public
  class MultipartPartTooLarge < QueryInvalid
  end

  # One part's header block past Multipart::MAX_HEADER_BYTES.
  # @api public
  class MultipartHeaderTooLarge < QueryInvalid
  end

  # The flat result of {Multipart.parse}: parallel typed Arrays, in the order
  # the parts arrived, not one Hash of mixed values. It
  # is named MultipartForm and not Multipart::Form: Class#name carried no
  # namespace on Spinel 2026.09.12, and the name is public API.
  # @api public
  class MultipartForm
    def initialize
      @text_names = Array.new(0) { "" }
      @text_values = Array.new(0) { "" }
      @file_names = Array.new(0) { "" }
      @files = Array.new(0) { UploadedFile.blank }
    end

    # @param name [String] the field name, valid UTF-8, brackets not yet split
    # @param value [String] the field's value, valid UTF-8
    # @return [nil]
    def add_text(name, value)
      @text_names << name
      @text_values << value
      nil
    end

    # @param name [String] the field name, valid UTF-8, brackets not yet split
    # @param upload [UploadedFile]
    # @return [nil]
    def add_file(name, upload)
      @file_names << name
      @files << upload
      nil
    end

    # The value of the LAST text part named exactly `name` (so `post[_method]`
    # is not `_method`), "" when there is none. What a CSRF check or a
    # method override reads through Request#form_or_query_value.
    # @param name [String]
    # @return [String]
    def text_value(name)
      i = @text_names.length - 1
      while i >= 0
        return @text_values[i] if @text_names[i] == name
        i -= 1
      end
      ""
    end

    # @return [Integer] the number of text parts
    def text_count
      @text_names.length
    end

    # @param i [Integer]
    # @return [String]
    def text_name_at(i)
      @text_names[i]
    end

    # @param i [Integer]
    # @return [String]
    def text_value_at(i)
      @text_values[i]
    end

    # @return [Integer] the number of file parts kept (an unselected file
    #   input is dropped by the parser)
    def file_count
      @files.length
    end

    # @param i [Integer]
    # @return [String]
    def file_name_at(i)
      @file_names[i]
    end

    # @param i [Integer]
    # @return [UploadedFile]
    def file_at(i)
      @files[i]
    end
  end

  # The multipart parser a {Request} calls ({Request.multipart_parser}); this
  # base is the null parser, the one a program that never requires
  # "spinel-http/multipart" has. It finds no boundary, and refuses to parse:
  # a multipart body is {UnsupportedMediaType}, a 415. Requiring
  # "spinel-http/multipart" installs a subclass that parses. A hook is a base
  # class with stub methods and an installed object (NOTES.md rule 13).
  # @api public
  class MultipartParser
    # @param content_type_header [String] the whole Content-Type header value
    # @return [String] "" (the null parser knows no boundary)
    def boundary_of(content_type_header)
      ""
    end

    # @param body [String]
    # @param content_type_header [String]
    # @return [MultipartForm]
    # @raise [UnsupportedMediaType] always
    def parse_form(body, content_type_header)
      raise UnsupportedMediaType, "multipart/form-data bodies are not supported: no multipart parser is installed (require \"spinel-http/multipart\")"
    end
  end
end
