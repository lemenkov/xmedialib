### ----------------------------------------------------------------------
### Heavily modified version of Peter Lemenkov. Big ups go to him
### for his excellent work in this area.
###
### @maintainer: Lee Sylvester <lee.sylvester@gmail.com>
###
### Copyright (c) 2012 Peter Lemenkov <lemenkov@gmail.com>
###
### All rights reserved.
###
### Redistribution and use in source and binary forms, with or without modification,
### are permitted provided that the following conditions are met:
###
### * Redistributions of source code must retain the above copyright notice, this
### list of conditions and the following disclaimer.
### * Redistributions in binary form must reproduce the above copyright notice,
### this list of conditions and the following disclaimer in the documentation
### and/or other materials provided with the distribution.
### * Neither the name of the authors nor the names of its contributors
### may be used to endorse or promote products derived from this software
### without specific prior written permission.
###
### THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ''AS IS'' AND ANY
### EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
### WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
### DISCLAIMED. IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE FOR ANY
### DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
### (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
### LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
### ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
### (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
### SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
###
### ----------------------------------------------------------------------

defmodule XMediaLib.Rtp do
  alias XMediaLib.{Rtcp, Rtp, Zrtp, Stun}

  @rtp_version 2

  @zrtp_marker 0x1000
  # <<"ZRTP">>, <<90,82,84,80>>
  @zrtp_magic_cookie 0x5A525450

  @stun_marker 0
  @stun_magic_cookie 0x2112A442

  defstruct padding: 0,
            marker: 0,
            payload_type: nil,
            sequence_number: nil,
            timestamp: nil,
            ssrc: nil,
            csrcs: [],
            extension: nil,
            payload: <<>>

  defmodule Extension do
    defstruct type: nil, payload: nil
  end

  # DTMF, see RFC 2833 and RFC 4733
  # http://www.rfc-editor.org/rfc/rfc2833.txt
  # http://www.rfc-editor.org/rfc/rfc4733.txt
  defmodule Dtmf do
    defstruct event: nil, eof: nil, volume: nil, duration: nil
  end

  # TONE, see RFC 4733
  # http://www.rfc-editor.org/rfc/rfc4733.txt
  defmodule Tone do
    defstruct modulation: nil, divider: nil, volume: nil, duration: nil, frequencies: []
  end

  # http://www.iana.org/assignments/rtp-parameters
  # http://en.wikipedia.org/wiki/RTP_audio_video_profile
  # See these RFCs for further details:

  # http://www.ietf.org/rfc/rfc2029.txt
  # http://www.ietf.org/rfc/rfc2190.txt
  # http://www.ietf.org/rfc/rfc2250.txt
  # http://www.ietf.org/rfc/rfc2435.txt
  # http://www.ietf.org/rfc/rfc2658.txt
  # http://www.ietf.org/rfc/rfc3389.txt
  # http://www.ietf.org/rfc/rfc3551.txt
  # http://www.ietf.org/rfc/rfc4587.txt
  # http://www.cisco.com/en/US/tech/tk652/tk698/technologies_tech_note09186a0080094ae2.shtml

  @rtp_payload_pcmu 0
  @rtp_payload_gsm 3
  @rtp_payload_g723 4
  @rtp_payload_dvi4_8khz 5
  @rtp_payload_dvi4_16khz 6
  @rtp_payload_lpc 7
  @rtp_payload_pcma 8
  @rtp_payload_g722 9
  @rtp_payload_l16_2ch 10
  @rtp_payload_l16_1ch 11
  @rtp_payload_qcelp 12
  # RFC 3389
  @rtp_payload_cn 13
  @rtp_payload_mpa 14
  @rtp_payload_g728 15
  @rtp_payload_dvi4_11khz 16
  @rtp_payload_dvi4_22khz 17
  @rtp_payload_g729 18
  # RFC 2029
  @rtp_payload_celb 25
  # RFC 2435
  @rtp_payload_jpeg 26
  @rtp_payload_nv 28
  # RFC 4587
  @rtp_payload_h261 31
  # RFC 2250
  @rtp_payload_mpv 32
  # RFC 2250
  @rtp_payload_mp2t 33
  @rtp_payload_h263 34

  # FIXME move to the header?
  @mbz 0

  #################################
  #
  #   Decoding functions
  #
  #################################

  def decode(
        <<@rtp_version::size(2), padding::size(1), extension_flag::size(1), cc::size(4),
          marker::size(1), payload_type::size(7), sequence_number::size(16), timestamp::size(32),
          ssrc::size(32), rest::binary>>
      )
      when payload_type <= 34 do
    size = cc * 4
    <<csrcs::binary-size(size), data::binary>> = rest
    {:ok, payload, extension} = decode_extension(data, extension_flag)

    {:ok,
     %Rtp{
       padding: padding,
       marker: marker,
       payload_type: payload_type,
       sequence_number: sequence_number,
       timestamp: timestamp,
       ssrc: ssrc,
       csrcs: for(<<csrc::size(32) <- csrcs>>, do: csrc),
       extension: extension,
       payload: payload
     }}
  end

  def decode(
        <<@rtp_version::size(2), padding::size(1), extension_flag::size(1), cc::size(4),
          marker::size(1), payload_type::size(7), sequence_number::size(16), timestamp::size(32),
          ssrc::size(32), rest::binary>>
      )
      when 96 <= payload_type do
    size = cc * 4
    <<csrcs::binary-size(size), data::binary>> = rest
    {:ok, payload, extension} = decode_extension(data, extension_flag)

    {:ok,
     %Rtp{
       padding: padding,
       marker: marker,
       payload_type: payload_type,
       sequence_number: sequence_number,
       timestamp: timestamp,
       ssrc: ssrc,
       csrcs: for(<<csrc::size(32) <- csrcs>>, do: csrc),
       extension: extension,
       payload:
         case Process.get(payload_type) do
           :undefined ->
             payload

           :dtmf ->
             {:ok, dtmf} = decode_dtmf(payload)
             dtmf

           _ ->
             payload
         end
     }}
  end

  def decode(<<@rtp_version::size(2), _::size(7), payload_type::size(7), rest::binary>> = bin)
      when 64 <= payload_type and payload_type <= 82,
      do: Rtcp.decode(bin)

  def decode(
        <<@zrtp_marker::size(16), _::size(16), @zrtp_magic_cookie::size(32), _::binary>> = bin
      ),
      do: Zrtp.decode(bin)

  def decode(
        <<@stun_marker::size(2), _::size(30), @stun_magic_cookie::size(32), _::binary>> = bin
      ),
      do: Stun.decode(bin)

  #################################
  #
  #   Decoding helpers
  #
  #################################

  def decode_extension(data, 0),
    do: {:ok, data, nil}

  def decode_extension(
        <<type::size(16), length::size(16), payload::binary-size(length), data::binary>>,
        1
      ),
      do: {:ok, data, %Extension{type: type, payload: payload}}

  #
  # RFC 2198, 2833, and 4733 decoding helpers
  #

  # DTMF with zero duration is possible. Im teams that this events lasts forever.
  def decode_dtmf(
        <<event::size(8), 0::size(1), _mbz::size(1), volume::size(6), duration::size(16)>>
      ),
      do: {:ok, %Dtmf{event: event, eof: false, volume: volume, duration: duration}}

  def decode_dtmf(
        <<event::size(8), 1::size(1), _mbz::size(1), volume::size(6), duration::size(16)>>
      ),
      do: {:ok, %Dtmf{event: event, eof: true, volume: volume, duration: duration}}

  def decode_dtmf(<<dtmf::binary-size(4), _rest::binary>>) do
    Logger.warning("Broken DTMF generator (Jitsi?)")
    decode_dtmf(dtmf)
  end

  # FIXME Tone with zero duration SHOULD be ignored (just drop it?)
  def decode_tone(
        <<modulation::size(9), divider::size(1), volume::size(6), duration::size(16),
          rest::binary>>
      ) do
    frequencies = for <<@mbz::size(4), frequency::size(12) <- rest>>, do: frequency

    {:ok,
     %Tone{
       modulation: modulation,
       divider: divider,
       volume: volume,
       duration: duration,
       frequencies: frequencies
     }}
  end

  def decode_red(redundant_payload),
    do: decode_red_headers(redundant_payload, [])

  def decode_red_headers(<<0::size(1), payload_type::size(7), data::binary>>, headers),
    do: decode_red_payload(headers ++ [{payload_type, 0, 0}], data)

  def decode_red_headers(
        <<1::size(1), payload_type::size(7), timestamp_offset::size(14), block_length::size(10),
          data::binary>>,
        headers
      ),
      do: decode_red_headers(data, headers ++ [{payload_type, timestamp_offset, block_length}])

  def decode_red_payload(headers, payload),
    do: decode_red_payload(headers, payload, [])

  def decode_red_payload([{payload_type, 0, 0}], <<payload::binary>>, payloads),
    do: {:ok, payloads ++ [{payload_type, 0, payload}]}

  def decode_red_payload(
        [{payload_type, timestamp_offset, block_length} | headers],
        data,
        payloads
      ) do
    <<payload::binary-size(block_length), rest::binary>> = data
    decode_red_payload(headers, rest, payloads ++ [{payload_type, timestamp_offset, payload}])
  end

  #################################
  #
  #   Encoding functions
  #
  #################################

  def encode(%Rtp{
        padding: p,
        marker: m,
        payload_type: pt,
        sequence_number: sn,
        timestamp: ts,
        ssrc: ssrc,
        csrcs: csrcs,
        extension: x,
        payload: payload
      })
      when is_binary(payload) do
    cc = length(csrcs)
    csrc_data = for <<csrc <- csrcs>>, into: "", do: <<csrc::size(32)>>
    {extension_flag, extension_data} = encode_extension(x)

    <<@rtp_version::size(2), p::size(1), extension_flag::size(1), cc::size(4), m::size(1),
      pt::size(7), sn::size(16), ts::size(32), ssrc::size(32), csrc_data::binary,
      extension_data::binary, payload::binary>>
  end

  def encode(%Rtp{payload: %Dtmf{} = payload} = rtp),
    do: encode(%Rtp{rtp | payload: encode_dtmf(payload)})

  def encode(%Rtp{payload: %Tone{} = payload} = rtp),
    do: encode(%Rtp{rtp | payload: encode_tone(payload)})

  def encode(%Zrtp{} = zrtp),
    do: Zrtp.encode(zrtp)

  def encode(%Stun{} = stun),
    do: Stun.encode(stun)

  def encode(%Rtcp{} = rtcp),
    do: Rtcp.encode(rtcp)

  #################################
  #
  #   Encoding helpers
  #
  #################################

  def encode_extension(nil),
    do: {0, <<>>}

  def encode_extension(%Extension{type: type, payload: payload}) do
    length = byte_size(payload)
    {1, <<type::size(16), length::size(16), payload::binary-size(length)>>}
  end

  #
  # RFC 2198, 2833, and 4733 encoding helpers
  #

  def encode_dtmf(%Dtmf{event: event, eof: false, volume: volume, duration: duration}),
    do: <<event::size(8), 0::size(1), 0::size(1), volume::size(6), duration::size(16)>>

  def encode_dtmf(%Dtmf{event: event, eof: true, volume: volume, duration: duration}),
    do: <<event::size(8), 1::size(1), 0::size(1), volume::size(6), duration::size(16)>>

  def encode_tone(%Tone{
        modulation: modulation,
        divider: divider,
        volume: volume,
        duration: duration,
        frequencies: frequencies
      }) do
    frequencies_bin =
      for <<frequency <- frequencies>>, into: "", do: <<0::size(4), frequency::size(12)>>

    <<modulation::size(9), divider::size(1), volume::size(6), duration::size(16),
      frequencies_bin::binary>>
  end

  def encode_red(redundant_payloads),
    do: encode_red(redundant_payloads, <<>>, <<>>)

  def encode_red([{payload_type, _, payload}], headers_binary, payload_binary),
    do:
      <<headers_binary::binary, 0::size(1), payload_type::size(7), payload_binary::binary,
        payload::binary>>

  def encode_red(
        [{payload_type, timestamp_offset, payload} | redundant_payloads],
        headers_binary,
        payload_binary
      ) do
    block_length = byte_size(payload)

    encode_red(
      redundant_payloads,
      <<headers_binary::binary, 1::size(1), payload_type::size(7), timestamp_offset::size(14),
        block_length::size(10)>>,
      <<payload_binary::binary, payload::binary>>
    )
  end
end
