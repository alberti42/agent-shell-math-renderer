"""Send the workflow's token with melpazoid's requests to api.github.com.

melpazoid fetches from the GitHub API with urllib and no token.  Python
imports this module when it starts, if its directory is on PYTHONPATH;
it installs an opener that adds GITHUB_TOKEN to requests to
api.github.com and to no other host.  Without GITHUB_TOKEN it does
nothing.
"""

import os
import urllib.request

_TOKEN = os.environ.get('GITHUB_TOKEN')


class _GitHubToken(urllib.request.BaseHandler):
    def http_request(self, request):
        if request.host == 'api.github.com':
            request.add_unredirected_header('Authorization', f'Bearer {_TOKEN}')
        return request

    https_request = http_request


if _TOKEN:
    urllib.request.install_opener(urllib.request.build_opener(_GitHubToken()))
