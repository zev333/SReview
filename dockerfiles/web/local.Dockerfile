FROM debian:trixie
RUN echo "deb http://deb.debian.org/debian sid main" > /etc/apt/sources.list.d/sid.list && \
  printf 'Package: *\nPin: release n=sid\nPin-Priority: 100\n' > /etc/apt/preferences.d/sid.pref && \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get --no-install-recommends install \
  bs1770gain \
  ca-certificates \
  curl \
  ffmpeg \
  fonts-font-awesome \
  inkscape \
  libclass-type-enum-perl \
  libcryptx-perl \
  libdatetime-format-iso8601-perl \
  libdatetime-format-pg-perl \
  libdatetime-perl \
  libextutils-depends-perl \
  libfile-which-perl \
  libjs-bootstrap4 \
  libjs-jquery \
  libjs-vue \
  libmojo-pg-perl \
  libmojolicious-perl \
  libmojolicious-plugin-openapi-perl \
  libmoose-perl \
  libnet-amazon-s3-perl \
  libtest-deep-perl \
  libtext-format-perl \
  libyaml-libyaml-perl \
  perl \
  postgresql-client \
  pwgen \
  python3-venv \
  -y && \
  apt-get install --no-install-recommends \
  -t sid \
  libmedia-convert-perl \
  -y

# Cache the OpenAPI 3.0 schema locally — the upstream URL returns 404
RUN curl -sL "https://raw.githubusercontent.com/OAI/OpenAPI-Specification/aa91a19c43f8a12c02efa42d64794e396473f3b1/schemas/v3.0/schema.json" \
    -o /usr/share/perl5/JSON/Validator/cache/a516498b60c53096b2ce2cd83ebe0abc

# torch without CUDA
RUN python3 -m venv /venv && /venv/bin/pip install torch --index-url https://download.pytorch.org/whl/cpu && /venv/bin/pip install openai-whisper

RUN mkdir /etc/sreview

WORKDIR /usr/share/sreview/

ADD /lib/ /usr/local/lib/site_perl/
ADD /scripts/sreview-config /usr/src/scripts/sreview-config

RUN cd /usr/src/scripts/ && ./sreview-config --action=update --set=adminpw=dev --set=adminuser=dev@dev.dev  --set=secret=INSECURE_DEV_SECRET --set=dbistring=dbi:Pg:dbname=sreviewdb\;host=db\;user=sreviewuser\;password=sreviewpassword --set=api_key=devkey --set=event=testevent --set=audio_multiplex_mode=none --set=preview_exten=mp4 --set=vid_prefix=

CMD ./sreview-web daemon
EXPOSE 8080
