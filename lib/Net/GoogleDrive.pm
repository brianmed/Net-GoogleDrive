package Net::GoogleDrive;

use common::sense;
use JSON;
use Mouse;
use LWP::UserAgent;
use HTTP::Request::Common;
use URI;

=head1 NAME

Net::GoogleDrive - A Google Drive API interface

=head1 VERSION

Version 0.02

=cut

our $VERSION = '0.02';

=head1 SYNOPSIS

Google Drive API is basd on OAuth. I try to abstract as much away as
possible so you should not need to know too much about it.  Kudos to
Net::Dropbox::API.

You must register with google, then request access to the google drive
api here: https://developers.google.com/drive/quickstart#enable_the_drive_api

This is how it works:

    use Net::GoogleDrive;

    my %args = (
        scope         => 'https://www.googleapis.com/auth/drive',
        redirect_uri  => 'urn:ietf:wg:oauth:2.0:oob',
        client_id     => '<provided by google>',
        client_secret => '<provided by google>',
    );

    my $gdrive = Net::GoogleDrive->new(%args);
    my $login_link = $gdrive->login_link();

    ... Time passes and the login link is clicked ...

    my $gdrive = Net::GoogleDrive->new(%args);

    # $auth_token will come from CGI or somesuch: Google gives it to you
    $gdrive->token($auth_token);

    my $files = $gdrive->files();

    foreach my $f (@{ $files->{items} }) {
        if ($f->{downloadUrl}) {
            open(my $fh, ">", "file.dl") or die("file.dl: $!\n");
            print($fh $gdrive->downloadUrl($f));
            close($fh);
        }
    }

Once you have the $auth_token, internally an $access_token will be retrieved
and stored.  If you want continued access to the google drive api over
multiple instances of your program or multiple CGI requests, you must store
access token and pass it in each time (otherwise you will be forced to
constantly log in and generate more auth tokens).  You can pass in an existing
access token using the access_token() method.

=head1 FUNCTIONS

=cut

has 'ua' => (is => 'rw', isa => 'LWP::UserAgent', default => sub { LWP::UserAgent->new() });
has 'debug' => (is => 'rw', isa => 'Bool', default => 0);
has 'error' => (is => 'rw', isa => 'Str', predicate => 'has_error');
has 'scope' => (is => 'rw', isa => 'Str', required => 'Str');
has 'redirect_uri' => (is => 'rw', isa => 'Str', required => 'Str');
has 'client_id' => (is => 'rw', isa => 'Str', required => 'Str');
has 'client_secret' => (is => 'rw', isa => 'Str');
has 'access_token' => (is => 'rw', isa => 'Str');

=head2 login_link

This returns the login URL. This URL has to be clicked by the user and the user then has
to accept the application in Google Drive. 

Google Drive then redirects back to the callback URI defined with
C<$self-E<gt>redirect_uri>.

=cut

sub login_link
{
    my $self = shift;

    my $uri = URI->new('https://accounts.google.com/o/oauth2/auth');

    $uri->query_form (
        response_type => "code",
        client_id => $self->client_id(),
        redirect_uri => $self->redirect_uri(),
        scope => $self->scope(),
    );

    return($uri->as_string());
}

=head2 token

This returns the Google Drive access token. This is needed to 
authorize with the API.

=cut

sub token
{
    my $self = shift;
    my $code = shift;

    my $req = &HTTP::Request::Common::POST(
        'https://accounts.google.com/o/oauth2/token',
        [
            code => $code,
            client_id => $self->client_id(),
            client_secret => $self->client_secret() || die("no client_secret given"),
            redirect_uri => $self->redirect_uri(),
            grant_type => 'authorization_code',
        ]
    );

    my $ua = $self->ua();
    my $res = $ua->request($req);

    if ($res->is_success()) {
        my $token = JSON::from_json($res->content());
        $self->access_token($token->{access_token});

        print "Got Access Token ", $res->access_token(), "\n" if $self->debug();
    }
    else {
        $self->error($res->status_line());
        warn "Something went wrong: ".$res->status_line();
    }
}

=head2 files

This returns a files Resource object from JSON.

=cut

sub files
{
    my $self = shift;

    my $req = HTTP::Request->new(
        GET => 'https://www.googleapis.com/drive/v2/files',
        HTTP::Headers->new(Authorization => "Bearer " . $self->access_token())
    );

    my $res = $self->ua()->request($req);

    if ($res->is_success()) {
        my $list = JSON::from_json($res->content());

        return($list);
    }
    else {
        $self->error($res->status_line());
        warn "Something went wrong: ".$res->status_line();
        return(undef);
    }
}

=head2 uploadSimple

This does a simple upload.  This method does one request to the google drive
api with the metadata, then a subsequent request to the google upload service
with the file content.  According to the google drive api documentation, this
should only be used on smaller files that don't need to resume if the transfer
fails (they can just be completely re-uploaded).

File metadata must be provided in a datastructure matching the documentation
here:

https://developers.google.com/drive/v2/reference/files/insert

In addition, provide a "data" key that contains the file content itself.  If
you have a file on the filesystem and you don't want to read it yourself
before uploading, try uploadMultipart().

 $gdrive->uploadSimple($file_ref);

Arguments:
    $file_ref - A datastructure (hashref) that holds file metadata (plus an
                extra "data" key that holds the file content)

=cut

sub uploadSimple
{
    my $self = shift;
    my $file_ref = shift;

    # The actual content of the file gets uploaded in a separate request
    my $data = delete $file_ref->{'data'};

    my $req = HTTP::Request->new(
        POST => 'https://www.googleapis.com/drive/v2/files',
        HTTP::Headers->new(
            'Authorization' => 'Bearer ' . $self->access_token(),
            'Content-Type'  => 'application/json',
        ),
    );

    $req->content(JSON::to_json($file_ref, { pretty => 1 }));

    my $res = $self->ua()->request($req);

    if(!$res->is_success()) {
        $self->error($res->status_line());
        warn "Something went wrong: " . $res->status_line();
        warn $res->content();
        return undef;
    }

    my $response = JSON::from_json($res->content());

    my $id = $response->{'id'};

    my $put_req = HTTP::Request->new(
        PUT => "https://www.googleapis.com/upload/drive/v2/files/$id?uploadType=media",
        HTTP::Headers->new(
            'Authorization' => 'Bearer ' . $self->access_token(),
            'Content-Type'  => $file_ref->{'mimeType'},
        ),
    );

    $put_req->content($data);

    my $put_response = $self->ua()->request($put_req);

    if(!$put_response->is_success()) {
        $self->error($put_response->status_line());
        warn "Something went wrong: " . $put_response->status_line();
        warn $put_response->content();
        return undef;
    }

    return JSON::from_json($put_response->content());
}

=head2 uploadMultipart

This does an upload with a multi-part post request.  This will be a single 
request and according to the google drive api documentation, should only be 
used on smaller files that don't need to resume if the transfer fails (they 
can just be completely re-uploaded).

File metadata must be provided in a datastructure matching the documentation
here:

https://developers.google.com/drive/v2/reference/files/insert

 $gdrive->uploadMultipart($file, $file_ref);

Arguments:
    $file - a path to a file on the filesystem
    $file_ref - A datastructure (hashref) that holds file metadata

=cut

sub uploadMultipart {
    my ($self, $file, $file_ref) = @_;

    # This function call is all sorts of weird.  See 
    # https://developers.google.com/drive/manage-uploads#multipart for more 
    # information on what the request should look like.  The Content key passed 
    # to POST is an arrayref to trigger multipart, and each part is unamed ('' 
    # for key), and each value is an arrayref to indicate to POST() that these 
    # are file uploads, NOT regular form data.  By default, POST() attempts to 
    # read the file from the fs, but we disallow that behavior in the json part 
    # since we have it in memory.
    my $req = HTTP::Request::Common::POST(
        'https://www.googleapis.com/upload/drive/v2/files?uploadType=multipart',
        Authorization => 'Bearer ' . $self->access_token(),
        Content_Type  => 'form-data',
        Content => [
            '' => [
                undef, # do not attempt to read this part from the fs
                '',    # no filename, it's a json part
                Content_Type => 'application/json',
                Content => JSON::to_json($file_ref, { pretty => 1 }),
            ],
            '' => [
                $file,                # POST() will read file from fs
                $file_ref->{'title'}, # Use the title as the filename
                Content_Type => $file_ref->{'mimeType'},
            ]
        ],
    );

    my $res = $self->ua()->request($req);

    if(!$res->is_success()) {
        $self->error($res->status_line());
        warn "Something went wrong: " . $res->status_line();
        warn $res->content();
        return undef;
    }

    return JSON::from_json($res->content());
}

=head2 downloadUrl

This returns the binary data from a file.

=cut

sub downloadUrl
{
    my $self = shift;
    my $file = shift;

    my $req = HTTP::Request->new(
        GET => $$file{downloadUrl},
        HTTP::Headers->new(Authorization => "Bearer " . $self->access_token())
    );

    my $res = $self->ua()->request($req);

    if ($res->is_success()) {
        return($res->content());
    }
    else {
        $self->error($res->status_line());
        warn "Something went wrong: ".$res->status_line();
        return(undef);
    }
}

=head2 FUTURE

More can be added if there is interest.

=cut

=head1 AUTHOR

Brian Medley, C<< <bpmedley at cpan.org> >>

=head1 BUGS

There are plenty.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Net::GoogleDrive

=head1 COPYRIGHT & LICENSE

Copyright 2012 Brian Medley.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut

1;
