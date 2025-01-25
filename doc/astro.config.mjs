import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import rehypeExternalLinks from 'rehype-external-links';
import { targetBlank } from './src/plugins/targetBlank';

// https://astro.build/config
export default defineConfig({
	site: 'https://darkone-linux.github.io',
	trailingSlash: "never",
	build: {
		assets: 'astro',
	},
	markdown: {
		rehypePlugins: [
			[targetBlank, { domain: 'darkone-linux.github.io' }],
			[
				rehypeExternalLinks,
				{
				  content: { type: 'text', value: ' ↗' }
				}
			],
		],
	},
	integrations: [
		starlight({
			title: "Darkone NixOS Framework",
			favicon: '/favicon.svg',
			customCss: [
				'./src/styles/custom.css',
			],
			locales: {
				root: {
						label: 'English',
						lang: 'en-US',
				},
			},
			social: {
				github: 'https://github.com/darkone-linux/darkone-nixos-framework',
			},
			logo: {
				src: './src/assets/nix-logo.svg',
			},
			sidebar: [
				{
					label: 'Documentation',
					autogenerate: { directory: 'doc' },
				},
				{
					label: 'References',
					autogenerate: { directory: 'ref' },
				},
				{ label: 'Changelog', slug: 'changelog' },
				{ label: 'Thanks!', slug: 'thanks' },
			],
		}),
	],
});
